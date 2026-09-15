defmodule Lei.Payments.TempoHttpTest do
  @moduledoc """
  Stablecoin through the HTTP surface: offered beside cards, answered, credited
  once, to the org it was issued to (#144).
  """
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Lei.{Credits, Wallets}
  alias Lei.Payments.{ChallengeStore, Http}
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}
  alias Lei.Payments.Rails.{Mpp, Tempo}

  setup :verify_on_exit!

  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
  @hash "0xcc03711d01ade07b5b546263d81bbe620a32ac12fe540736e5d5f2780c152cf6"

  setup do
    Lei.RateLimiter.clear()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    saved =
      for k <- [:stripe_secret_key, :tempo_deposit_address, :tempo_poll_interval_ms],
          do: {k, Application.get_env(:lowendinsight, k)}

    Application.put_env(
      :lowendinsight,
      :stripe_secret_key,
      "sk_test_" <> String.duplicate("x", 24)
    )

    Application.put_env(:lowendinsight, :tempo_deposit_address, @deposit)
    Application.put_env(:lowendinsight, :tempo_poll_interval_ms, 0)

    on_exit(fn ->
      for {k, v} <- saved do
        if v,
          do: Application.put_env(:lowendinsight, k, v),
          else: Application.delete_env(:lowendinsight, k)
      end
    end)

    {:ok, org} = Wallets.provision("0x" <> String.duplicate("b", 39) <> "2")
    %{org: org}
  end

  defp receipt do
    Path.join([__DIR__, "..", "..", "fixtures", "tempo", "memo_to_deposit.json"])
    |> File.read!()
    |> Poison.decode!()
  end

  defp offer(org, opts \\ []) do
    # 500 credits, $0.50: what the real testnet transfer paid. The memo is the
    # one it carried, so the real receipt binds to this challenge.
    Http.challenge(
      conn(:get, "/v1/analyze"),
      org.id,
      500,
      # Overrides first: Keyword.get takes the first match.
      opts ++
        [
          rails: [Mpp, Tempo],
          confirmed?: fn _ -> true end,
          memo: "0xc09702f8182f5d94a23d75cc4c2e9835510fde10de3f5e6f20f2387b799f1ef0"
        ]
    )
  end

  defp challenges(conn) do
    conn
    |> get_resp_header("www-authenticate")
    |> Enum.map(fn h ->
      {:ok, c} = Challenge.from_header(h)
      c
    end)
  end

  defp credential_header(challenge) do
    Credential.to_header(%Credential{
      challenge: %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      },
      payload: %{"type" => "hash", "hash" => @hash},
      source: "did:pkh:eip155:42431:0x95b01240addf561daa31b76b1e8f89f8c4287917"
    })
  end

  defp settled_intent do
    %{
      "id" => "pi_tempo_http",
      "status" => "succeeded",
      "amount_received" => 50,
      "latest_charge" => %{
        "payment_method_details" => %{
          "crypto" => %{"buyer_address" => "0x95b0", "token_currency" => "usdc"}
        }
      }
    }
  end

  test "a 402 offers card and stablecoin, one WWW-Authenticate each", %{org: org} do
    conn = offer(org)

    assert conn.status == 402
    assert conn |> challenges() |> Enum.map(& &1.method) |> Enum.sort() == ["stripe", "tempo"]

    body = Poison.decode!(conn.resp_body)
    assert body["challenges"] |> Enum.map(& &1["method"]) |> Enum.sort() == ["stripe", "tempo"]

    # Both recorded: either may be the one answered.
    for c <- challenges(conn), do: assert({:ok, _, _} = ChallengeStore.fetch(c.id))
  end

  test "an unavailable rail is left out, not failed", %{org: org} do
    conn = offer(org, confirmed?: fn _ -> false end)

    assert conn.status == 402
    assert conn |> challenges() |> Enum.map(& &1.method) == ["stripe"]
  end

  test "when no rail is available, 402 says payment is unavailable", %{org: org} do
    conn = offer(org, rails: [Tempo], confirmed?: fn _ -> false end)

    assert conn.status == 402
    assert get_resp_header(conn, "www-authenticate") == []
    assert Poison.decode!(conn.resp_body)["payment"] == "unavailable"
  end

  test "a stablecoin credential is verified, credited and receipted", %{org: org} do
    tempo = offer(org) |> challenges() |> Enum.find(&(&1.method == "tempo"))

    expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, @hash -> {:ok, receipt()} end)

    expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
      {:ok, %{"id" => "pi_tempo_http", "status" => "processing"}}
    end)

    expect(Lei.StripeMock, :retrieve_payment_intent, fn _ -> {:ok, settled_intent()} end)

    conn = conn(:get, "/v1/analyze") |> put_req_header("authorization", credential_header(tempo))
    assert {:ok, conn, settlement} = Http.settle(conn)

    assert settlement.rail == "tempo"
    assert Credits.balance(org.id) == 500

    [header] = get_resp_header(conn, "payment-receipt")
    {:ok, receipt} = Receipt.from_header(header)
    assert receipt.method == "tempo"
    assert receipt.reference == "pi_tempo_http"

    entry = Lei.Repo.get_by!(Lei.CreditEntry, org_id: org.id, reason: "purchase:tempo")
    assert entry.external_ref == "tempo:pi_tempo_http"
  end

  test "the same transfer presented twice credits once", %{org: org} do
    tempo = offer(org) |> challenges() |> Enum.find(&(&1.method == "tempo"))

    stub(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)
    stub(Lei.StripeMock, :create_crypto_verification_intent, fn _ -> {:ok, settled_intent()} end)

    header = credential_header(tempo)

    for _ <- 1..2 do
      conn = conn(:get, "/v1/analyze") |> put_req_header("authorization", header)
      assert {:ok, _conn, _} = Http.settle(conn)
    end

    assert Credits.balance(org.id) == 500
  end
end
