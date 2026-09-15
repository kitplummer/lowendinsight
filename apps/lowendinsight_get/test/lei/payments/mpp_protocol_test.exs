defmodule Lei.Payments.Mpp.ProtocolTest do
  use ExUnit.Case, async: true

  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}

  defp challenge(overrides \\ []) do
    Keyword.merge(
      [
        id: "x7Tg2pLqR9mKvNwY3hBcZa",
        realm: "lowendinsight.dev",
        method: "stripe",
        intent: "charge",
        request: %{"amount" => "15.00", "currency" => "usd", "credits" => 15_000}
      ],
      overrides
    )
    |> Challenge.new()
  end

  defp echo(%Challenge{} = c) do
    %{
      "id" => c.id,
      "realm" => c.realm,
      "method" => c.method,
      "intent" => c.intent,
      "request" => Challenge.encode_json(c.request)
    }
  end

  describe "the challenge header" do
    test "renders the scheme and the required parameters" do
      header = Challenge.to_header(challenge())

      assert String.starts_with?(header, "Payment ")
      assert header =~ ~s(id="x7Tg2pLqR9mKvNwY3hBcZa")
      assert header =~ ~s(realm="lowendinsight.dev")
      assert header =~ ~s(method="stripe")
      assert header =~ ~s(intent="charge")
      assert header =~ "request="
    end

    test "round-trips" do
      original = challenge(expires: ~U[2026-09-13 12:05:00Z], description: "15,000 credits")

      assert {:ok, parsed} = original |> Challenge.to_header() |> Challenge.from_header()

      assert parsed.id == original.id
      assert parsed.realm == original.realm
      assert parsed.request == original.request
      assert parsed.description == original.description
      assert DateTime.compare(parsed.expires, original.expires) == :eq
    end

    test "is byte-identical across renders" do
      c = challenge()
      assert Challenge.to_header(c) == Challenge.to_header(c)
    end

    test "encodes request as base64url without padding, as the spec requires" do
      [_, encoded] = Regex.run(~r/request="([^"]+)"/, Challenge.to_header(challenge()))

      refute encoded =~ "="
      refute encoded =~ "+"
      refute encoded =~ "/"
      assert {:ok, _} = Challenge.decode_json(encoded)
    end

    test "canonicalises the request so key order cannot vary" do
      a = Challenge.encode_json(%{"b" => 1, "a" => 2, "c" => %{"z" => 1, "y" => 2}})
      b = Challenge.encode_json(%{"c" => %{"y" => 2, "z" => 1}, "a" => 2, "b" => 1})

      assert a == b
    end

    test "sorts keys even past the size where Elixir stops doing it for us" do
      # Maps of 32 keys or fewer already iterate in sorted order, so a small
      # map cannot tell whether anything is canonicalising. Above that Elixir
      # switches representation and iterates in hash order -- ["k24", "k16",
      # "k28", ...] -- which is deterministic but not JCS.
      #
      # JCS is what the payment network signs over, so unsorted output is a
      # signature mismatch against any implementation that follows the spec.
      request = for i <- 1..40, into: %{}, do: {"k#{String.pad_leading("#{i}", 2, "0")}", i}

      keys =
        request
        |> Challenge.encode_json()
        |> Base.url_decode64!(padding: false)
        |> then(&Regex.scan(~r/"(k\d\d)":/, &1))
        |> Enum.map(fn [_, k] -> k end)

      assert length(keys) == 40

      assert keys == Enum.sort(keys),
             "JCS requires sorted keys; got #{inspect(Enum.take(keys, 5))}"
    end

    test "sorts nested keys too" do
      nested = %{
        "outer" => for(i <- 1..40, into: %{}, do: {"n#{String.pad_leading("#{i}", 2, "0")}", i})
      }

      keys =
        nested
        |> Challenge.encode_json()
        |> Base.url_decode64!(padding: false)
        |> then(&Regex.scan(~r/"(n\d\d)":/, &1))
        |> Enum.map(fn [_, k] -> k end)

      assert keys == Enum.sort(keys)
    end

    test "generates a distinct id when none is given" do
      refute Challenge.new(realm: "r", request: %{}).id ==
               Challenge.new(realm: "r", request: %{}).id
    end

    test "refuses a header that is not a Payment challenge" do
      assert {:error, :not_a_payment_challenge} = Challenge.from_header("Bearer abc")
    end

    test "reports a missing required parameter rather than guessing" do
      header = ~s(Payment id="a", method="stripe", intent="charge", request="e30")

      assert {:error, {:missing_parameter, "realm"}} = Challenge.from_header(header)
    end
  end

  describe "expiry" do
    test "a challenge without an expiry does not expire" do
      refute Challenge.expired?(challenge())
    end

    test "a past expiry is expired" do
      assert Challenge.expired?(challenge(expires: ~U[2020-01-01 00:00:00Z]))
    end

    test "a future expiry is not" do
      refute Challenge.expired?(challenge(expires: ~U[2099-01-01 00:00:00Z]))
    end
  end

  describe "the credential header" do
    test "round-trips" do
      issued = challenge()

      credential = %Credential{
        challenge: echo(issued),
        payload: %{"spt" => "spt_test_123"},
        source: "acct_agent"
      }

      assert {:ok, parsed} = credential |> Credential.to_header() |> Credential.from_header()

      assert parsed.payload == credential.payload
      assert parsed.source == "acct_agent"
      assert parsed.challenge["id"] == issued.id
    end

    test "a credential need not name a source" do
      credential = %Credential{challenge: echo(challenge()), payload: %{"spt" => "x"}}

      assert {:ok, parsed} = credential |> Credential.to_header() |> Credential.from_header()
      assert is_nil(parsed.source)
    end

    test "refuses anything that is not a credential" do
      assert {:error, :no_credential} = Credential.from_header(nil)
      assert {:error, :not_a_payment_credential} = Credential.from_header("Bearer abc")
      assert {:error, :malformed_credential} = Credential.from_header("Payment !!!not-base64!!!")
    end

    test "refuses a credential missing its challenge or payload" do
      encoded =
        %{"payload" => %{"spt" => "x"}} |> Poison.encode!() |> Base.url_encode64(padding: false)

      assert {:error, :malformed_credential} = Credential.from_header("Payment " <> encoded)
    end
  end

  describe "cross-resource substitution" do
    test "a credential echoing the issued challenge matches" do
      issued = challenge()

      assert Credential.matches?(
               %Credential{challenge: echo(issued), payload: %{"spt" => "x"}},
               issued
             )
    end

    test "a proof bought for another challenge does not match" do
      # The attack: buy something cheap, spend the proof on something dear.
      cheap = challenge(id: "cheap-one", request: %{"amount" => "0.01", "credits" => 10})
      dear = challenge(id: "dear-one", request: %{"amount" => "15.00", "credits" => 15_000})

      refute Credential.matches?(
               %Credential{challenge: echo(cheap), payload: %{"spt" => "x"}},
               dear
             )
    end

    test "the same id with a different amount does not match" do
      # The subtler version, and the one an id-only check would let through.
      issued = challenge()

      tampered =
        issued
        |> echo()
        |> Map.put("request", Challenge.encode_json(%{"amount" => "0.01", "credits" => 15_000}))

      refute Credential.matches?(%Credential{challenge: tampered, payload: %{}}, issued)
    end

    test "a different realm does not match" do
      # A proof issued by another service is a real payment -- to someone else.
      issued = challenge()
      other = issued |> echo() |> Map.put("realm", "someone-else.example")

      refute Credential.matches?(%Credential{challenge: other, payload: %{}}, issued)
    end

    test "a different method does not match" do
      issued = challenge()
      other = issued |> echo() |> Map.put("method", "tempo")

      refute Credential.matches?(%Credential{challenge: other, payload: %{}}, issued)
    end

    test "an absent request does not match" do
      issued = challenge()
      without = issued |> echo() |> Map.delete("request")

      refute Credential.matches?(%Credential{challenge: without, payload: %{}}, issued)
    end

    test "a request echoed as a decoded map matches if it canonicalises the same" do
      issued = challenge()
      decoded = issued |> echo() |> Map.put("request", issued.request)

      assert Credential.matches?(%Credential{challenge: decoded, payload: %{}}, issued)
    end
  end

  describe "the receipt header" do
    test "round-trips" do
      receipt =
        Receipt.new(method: "stripe", reference: "pi_3ABC", timestamp: ~U[2026-09-13 12:00:00Z])

      assert {:ok, parsed} = receipt |> Receipt.to_header() |> Receipt.from_header()

      assert parsed.method == "stripe"
      assert parsed.reference == "pi_3ABC"
      assert parsed.status == "success"
      assert DateTime.compare(parsed.timestamp, receipt.timestamp) == :eq
    end

    test "refuses a malformed receipt" do
      assert {:error, :malformed_receipt} = Receipt.from_header("not-base64!!")

      assert {:error, :malformed_receipt} =
               Receipt.from_header(Base.url_encode64("{}", padding: false))
    end
  end
end
