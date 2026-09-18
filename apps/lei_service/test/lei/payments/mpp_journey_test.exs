defmodule Lei.Payments.JourneyTest do
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Wallets}
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}

  @moduledoc """
  The journey #104 exists for: an agent that has never been here goes from
  refusal to result without a human involved.

  Deliberately exercised through the real route rather than the payment modules
  directly. Every piece of this was tested in isolation and the point is that
  they compose -- the 402 comes back from the endpoint an agent would actually
  call, and the credential goes back to the same one.
  """

  @opts Lei.Web.Router.init([])

  setup :verify_on_exit!

  setup do
    Lei.RateLimiter.clear()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})

    address = "0x" <> String.duplicate("b", 39) <> "2"
    {:ok, org} = Wallets.provision(address)
    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "agent", ["analyze"])

    %{org: org, key: raw_key}
  end

  defp analyze(key, credential \\ nil) do
    conn(:post, "/v1/analyze/batch", body())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", credential || "Bearer #{key}")
    |> Lei.Web.Router.call(@opts)
  end

  defp body do
    Poison.encode!(%{
      "dependencies" => [
        %{"ecosystem" => "hex", "package" => "poison", "version" => "5.0.0"}
      ]
    })
  end

  # The credential occupies Authorization, per the spec. A wallet-identified
  # agent has no API key -- the payment is how it identifies itself -- so the
  # two never contend in practice.
  defp analyze_with_payment(_key, credential), do: analyze(nil, credential)

  defp credential_for(challenge) do
    Credential.to_header(%Credential{
      challenge: %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      },
      payload: %{"spt" => "spt_journey"},
      source: "acct_agent"
    })
  end

  # Credits bought, which settles synchronously inside the request. The balance
  # is the purchase minus whatever the async usage recorder has got to, and is
  # therefore not a stable thing to assert on immediately after a response.
  defp purchased(org) do
    Credits.entries(org.id)
    |> Enum.filter(&String.starts_with?(&1.reason, "purchase:"))
    |> Enum.map(& &1.delta)
    |> Enum.sum()
  end

  defp intent do
    %{
      "id" => "pi_journey_1",
      "status" => "succeeded",
      "amount" => 1500,
      "amount_received" => 1500,
      "currency" => "usd"
    }
  end

  describe "an unfunded agent" do
    test "is refused with a payment challenge, not a bare error", %{key: key, org: org} do
      assert Credits.balance(org.id) == 0

      conn = analyze(key)

      assert conn.status == 402
      assert [header] = get_resp_header(conn, "www-authenticate")
      assert {:ok, challenge} = Challenge.from_header(header)
      assert challenge.request["credits"] == 15_000
      assert challenge.request["amount"] == "1500"
    end

    test "the challenge names this org, so the payment cannot be redirected", %{
      key: key,
      org: org
    } do
      conn = analyze(key)
      [header] = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Challenge.from_header(header)

      assert {:ok, _challenge, record} = Lei.Payments.ChallengeStore.fetch(challenge.id)
      assert record.org_id == org.id
    end

    test "asks for a block rather than the price of one analysis", %{key: key} do
      # Settling costs something on every rail, so charging per analysis would
      # spend more collecting than the analysis is worth.
      conn = analyze(key)
      body = Poison.decode!(conn.resp_body)

      assert body["credits"] == 15_000
    end
  end

  describe "paying" do
    test "the paid retry is served, and served because it paid", %{key: key, org: org} do
      # The claim #104 exists for. An earlier version of this test asserted the
      # balance and stopped -- which passed for the wrong reason, because with
      # no API key the quota check was skipped rather than satisfied.
      conn = analyze(key)
      assert conn.status == 402

      [header] = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Challenge.from_header(header)

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ -> {:ok, intent()} end)

      paid = analyze_with_payment(key, credential_for(challenge))

      assert paid.status == 200, "a paid request was not served: #{paid.status}"

      # The quota check ran against the funded org rather than being skipped.
      # The billing block is the evidence: it is built from the billing context
      # and is absent when no org is known, which is precisely the state the
      # old version of this test was passing in.
      body = Poison.decode!(paid.resp_body)

      # The tier has to be the org's own. The router emits "unknown" when no org
      # is in context, so merely asserting the field is truthy passes in
      # exactly the state this test exists to rule out -- which it did, until
      # the guard mutation said so.
      assert body["billing"]["tier"] == "free",
             "billing tier was #{inspect(body["billing"]["tier"])}: the request was served " <>
               "without an org, not because it paid"

      # Deliberately not asserting the balance. Usage is recorded through
      # a task, so the debit landed some time after the response --
      # asserting on it either way races, and both directions of that
      # assertion have now failed here under load. What is synchronous is the
      # purchase, so that is what is checked.
      assert purchased(org) == 15_000
    end

    test "a credential on the retry credits the org", %{key: key, org: org} do
      conn = analyze(key)
      [header] = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Challenge.from_header(header)

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ -> {:ok, intent()} end)

      paid = analyze_with_payment(key, credential_for(challenge))

      # The purchase, not the balance: a served request debits asynchronously,
      # so the balance at this moment depends on timing.
      assert purchased(org) == 15_000
      assert [receipt_header] = get_resp_header(paid, "payment-receipt")

      assert {:ok, %Receipt{reference: "pi_journey_1", method: "mpp"}} =
               Receipt.from_header(receipt_header)
    end

    test "a second identical retry does not pay twice", %{key: key, org: org} do
      conn = analyze(key)
      [header] = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Challenge.from_header(header)
      credential = credential_for(challenge)

      expect(Lei.StripeMock, :confirm_shared_payment_token, 2, fn _ -> {:ok, intent()} end)

      analyze_with_payment(key, credential)
      analyze_with_payment(key, credential)

      # Asserted on the purchases rather than the balance: now that a paid
      # request is actually served, the analysis debits and the balance is no
      # longer a clean measure of how many times we were paid.
      purchases =
        Credits.entries(org.id)
        |> Enum.filter(&(&1.reason == "purchase:mpp"))

      assert length(purchases) == 1
      assert Enum.sum(Enum.map(purchases, & &1.delta)) == 15_000
    end

    test "an org in debt is topped up past zero, not back to it", %{key: key, org: org} do
      # Otherwise it would be funded to a negative balance and refused again
      # on the very next request.
      {:ok, _} = Credits.debit(org.id, 500, "debit:analysis")
      assert Credits.balance(org.id) == -500

      conn = analyze(key)
      body = Poison.decode!(conn.resp_body)

      assert body["credits"] == 15_500
    end
  end
end
