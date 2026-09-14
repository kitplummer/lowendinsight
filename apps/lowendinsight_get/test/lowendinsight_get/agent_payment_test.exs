defmodule LowendinsightGet.AgentPaymentTest do
  @moduledoc """
  An agent that has never been here pays with stablecoin and is served (#147).

  Driven through LowendinsightGet.Endpoint, the thing deployed. #131 and #146
  were tested against Lei.Web.Router and the rails directly, and every one of
  those tests passed while production answered an agent with 401: this
  endpoint's auth plug rejected the Payment scheme before anything behind it
  ran, and its own POST /v1/analyze had no payment path at all.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Mox
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Wallets}
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}

  @opts LowendinsightGet.Endpoint.init([])
  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
  @payer "0x95b01240addf561daa31b76b1e8f89f8c4287917"
  @hash "0xcc03711d01ade07b5b546263d81bbe620a32ac12fe540736e5d5f2780c152cf6"
  @fixtures Path.expand("../../../lowendinsight/test/fixtures/tempo", __DIR__)

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    LowendinsightGet.Plugs.RateLimiter.clear()

    keys = [
      :stripe_secret_key,
      :tempo_deposit_address,
      :tempo_poll_interval_ms,
      :stripe_profile_id
    ]

    saved = for k <- keys, do: {k, Application.fetch_env(:lowendinsight, k)}

    Application.put_env(
      :lowendinsight,
      :stripe_secret_key,
      "sk_test_" <> String.duplicate("x", 24)
    )

    Application.put_env(:lowendinsight, :tempo_deposit_address, @deposit)
    Application.put_env(:lowendinsight, :tempo_poll_interval_ms, 0)

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:lowendinsight, k, value)
          :error -> Application.delete_env(:lowendinsight, k)
        end
      end

      # Leave the application's checker as the rest of the suite expects it.
      send(Lei.Stripe.ObjectCheck, :check)
    end)

    confirm_deposit_address()
    :ok
  end

  # Through the real confirmation path: the application's checker asks
  # (mocked) Stripe for the account's deposit addresses. No test seam.
  defp confirm_deposit_address do
    stub(Lei.StripeMock, :retrieve_price, fn _ -> {:ok, %{"active" => true}} end)
    stub(Lei.StripeMock, :list_deposit_addresses, fn "tempo" -> {:ok, [@deposit]} end)
    send(Lei.Stripe.ObjectCheck, :check)

    Enum.reduce_while(1..100, false, fn _, _ ->
      if Lei.Stripe.ObjectCheck.deposit_address_confirmed?(@deposit),
        do: {:halt, true},
        else: Process.sleep(10) && {:cont, false}
    end) || flunk("deposit address never confirmed")
  end

  defp post_batch(headers \\ []) do
    body = %{
      "dependencies" => [%{"ecosystem" => "npm", "package" => "left-pad", "version" => "1.3.0"}]
    }

    Enum.reduce(headers, conn(:post, "/v1/analyze/batch", body), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  defp challenges(conn) do
    conn
    |> get_resp_header("www-authenticate")
    |> Enum.map(fn h ->
      {:ok, c} = Challenge.from_header(h)
      c
    end)
  end

  # The real testnet receipt, with its memo and amount rewritten to answer
  # this challenge -- as an agent's own transfer would.
  defp receipt_for(challenge) do
    memo = get_in(challenge.request, ["methodDetails", "memo"])
    amount = String.to_integer(challenge.request["amount"])
    topic = Lei.Tempo.Transfer.transfer_with_memo_topic()

    Path.join(@fixtures, "memo_to_deposit.json")
    |> File.read!()
    |> Poison.decode!()
    |> Map.update!("logs", fn logs ->
      Enum.map(logs, fn
        %{"topics" => [^topic, from, to, _memo]} = log ->
          %{
            log
            | "topics" => [topic, from, to, memo],
              "data" => "0x" <> String.pad_leading(Integer.to_string(amount, 16), 64, "0")
          }

        log ->
          log
      end)
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
      source: "did:pkh:eip155:42431:#{@payer}"
    })
  end

  defp expect_settlement(challenge, times \\ 1) do
    expect(Lei.TempoRpcMock, :get_transaction_receipt, times, fn _, @hash ->
      {:ok, receipt_for(challenge)}
    end)

    stub(Lei.StripeMock, :create_crypto_verification_intent, fn params ->
      {:ok,
       %{
         "id" => "pi_agent_1",
         "status" => "succeeded",
         "amount_received" => params.amount,
         "latest_charge" => %{
           "payment_method_details" => %{
             "crypto" => %{"buyer_address" => @payer, "token_currency" => "usdc"}
           }
         }
       }}
    end)
  end

  describe "an agent that has never been here" do
    test "is asked to pay, not told to authenticate" do
      conn = post_batch()

      assert conn.status == 402
      methods = conn |> challenges() |> Enum.map(& &1.method)

      # Stablecoin only: the transfer's sender is who the org belongs to. A
      # card token identifies no one, so card is not offered anonymously yet.
      assert methods == ["tempo"]
    end

    test "is asked to pay on /v1/analyze too, the route agents actually call" do
      conn =
        conn(:post, "/v1/analyze", %{"urls" => ["https://github.com/kitplummer/lita-cron"]})
        |> LowendinsightGet.Endpoint.call(@opts)

      assert conn.status == 402
      assert conn |> challenges() |> Enum.map(& &1.method) == ["tempo"]
    end

    test "pays, is served, gets an org for its wallet and a key to come back with" do
      [challenge] = post_batch() |> challenges()
      expect_settlement(challenge)

      conn = post_batch([{"authorization", credential_header(challenge)}])

      assert conn.status == 200, conn.resp_body
      assert [receipt] = get_resp_header(conn, "payment-receipt")
      assert {:ok, %{method: "tempo", reference: "pi_agent_1"}} = Receipt.from_header(receipt)

      # The org is the wallet that paid, taken from the transfer on chain.
      assert %Lei.Org{} = org = Wallets.find_by_address(@payer)
      assert Credits.balance(org.id) > 0
      assert Credits.balance(org.id) <= 15_000

      assert [raw_key] = get_resp_header(conn, "lei-api-key")
      assert {:ok, api_key} = ApiKeys.authenticate_key(raw_key)
      assert api_key.org_id == org.id
    end

    test "comes back with its key and spends its balance without paying again" do
      [challenge] = post_batch() |> challenges()
      expect_settlement(challenge)

      [raw_key] =
        post_batch([{"authorization", credential_header(challenge)}])
        |> get_resp_header("lei-api-key")

      org = Wallets.find_by_address(@payer)
      before = wait_for_balance(org.id)

      conn = post_batch([{"authorization", "Bearer " <> raw_key}])

      assert conn.status == 200, conn.resp_body
      assert get_resp_header(conn, "www-authenticate") == []
      assert wait_for_balance(org.id, &(&1 < before)) < before
    end

    test "paying on /v1/analyze debits the paying org for the analysis it is served" do
      # This route billed by API key alone. A paying agent has no key on the
      # request that pays, so it would have been served with its balance
      # untouched. A cached report keeps this off the network.
      url = "https://github.com/kitplummer/agent-payment-billing"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      LowendinsightGet.Datastore.write_to_cache(url, %{
        data: %{repo: url},
        header: %{end_time: now, start_time: now, uuid: "agent-billing"}
      })

      analyze = fn headers ->
        Enum.reduce(headers, conn(:post, "/v1/analyze", %{"urls" => [url]}), fn {k, v}, c ->
          put_req_header(c, k, v)
        end)
        |> LowendinsightGet.Endpoint.call(@opts)
      end

      [challenge] = analyze.([]) |> challenges()
      expect_settlement(challenge)

      conn = analyze.([{"authorization", credential_header(challenge)}])
      assert conn.status == 200, conn.resp_body

      org = Wallets.find_by_address(@payer)
      assert wait_for_balance(org.id, &(&1 < 15_000)) < 15_000
    end

    test "a replayed payment credits once and issues no second key" do
      [challenge] = post_batch() |> challenges()
      expect_settlement(challenge, 2)
      header = credential_header(challenge)

      first = post_batch([{"authorization", header}])
      second = post_batch([{"authorization", header}])

      assert [_] = get_resp_header(first, "lei-api-key")
      assert get_resp_header(second, "lei-api-key") == []

      org = Wallets.find_by_address(@payer)

      purchases =
        Lei.Repo.all(
          from(e in Lei.CreditEntry,
            where: e.org_id == ^org.id and e.reason == "purchase:tempo"
          )
        )

      assert length(purchases) == 1
    end

    test "a wallet that already has an org is credited there, not given another" do
      {:ok, existing} = Wallets.provision(@payer)
      [challenge] = post_batch() |> challenges()
      expect_settlement(challenge)

      assert post_batch([{"authorization", credential_header(challenge)}]).status == 200

      assert Credits.balance(existing.id) > 0

      assert Lei.Repo.aggregate(
               from(o in Lei.Org, where: o.wallet_address == ^@payer),
               :count
             ) == 1
    end

    test "a credential that does not verify is asked to pay again, and no org is created" do
      [challenge] = post_batch() |> challenges()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:error, :not_found} end)

      conn = post_batch([{"authorization", credential_header(challenge)}])

      assert conn.status == 402
      assert Wallets.find_by_address(@payer) == nil
    end
  end

  describe "what stays closed" do
    test "a malformed bearer is still 401" do
      assert post_batch([{"authorization", "Bearer nonsense"}]).status == 401
    end

    test "routes that are not paid still require authentication" do
      for {method, path} <- [
            {:get, "/v1/usage"},
            {:get, "/v1/orgs"},
            {:post, "/v1/cache/invalidate"}
          ] do
        conn = conn(method, path) |> LowendinsightGet.Endpoint.call(@opts)
        assert conn.status == 401, "#{method} #{path} answered #{conn.status}"
      end
    end

    test "an anonymous request is never served for free when no rail can take payment" do
      Application.delete_env(:lowendinsight, :tempo_deposit_address)
      conn = post_batch()

      assert conn.status == 402
      assert Poison.decode!(conn.resp_body)["payment"] == "unavailable"
    end
  end

  describe "a wallet org with a key and no credits" do
    test "gets a challenge on /v1/analyze rather than a 500" do
      {:ok, org} = Wallets.provision("0x" <> String.duplicate("c", 40))
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "agent", ["analyze"])

      conn =
        conn(:post, "/v1/analyze", %{"urls" => ["https://github.com/kitplummer/lita-cron"]})
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> LowendinsightGet.Endpoint.call(@opts)

      assert conn.status == 402
      assert "tempo" in (conn |> challenges() |> Enum.map(& &1.method))
    end
  end

  defp wait_for_balance(org_id, until \\ fn _ -> true end) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      balance = Credits.balance(org_id)
      if until.(balance), do: {:halt, balance}, else: Process.sleep(20) && {:cont, balance}
    end)
  end
end
