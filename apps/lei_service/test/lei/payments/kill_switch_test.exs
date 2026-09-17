defmodule Lei.Payments.KillSwitchTest do
  @moduledoc """
  Any payment path can be switched off in seconds, without a deploy, and a
  switched-off path credits nothing (#139, stage F).

  Before this, stopping a rail meant a deploy: an incident response measured in
  minutes of CI. Decided 2026-09-17:

    * four switches: `mpp` and `tempo` (the machine rails), `acp` (agent card
      checkout) and `pro_checkout` (the human Pro plan)
    * off means **no new payment is offered, and nothing is credited**, including
      for a challenge issued before the switch
    * a stablecoin (`tempo`) credential refused while off is **held**: the agent
      sent the money on chain before presenting it, so the challenge and the
      credential are kept to be credited or refunded later
    * a Pro checkout completed while off is answered with an error, so Stripe
      retries the webhook and it applies once the switch is back on

  Machine rails go through `Lei.Payments.Http` with the chain and Stripe mocked,
  as in `Lei.Payments.TempoHttpTest`; the human side and the operator API
  through their routers.
  """
  use ExUnit.Case, async: false

  import Mox
  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Org, Repo, Wallets}
  alias Lei.Payments.{ChallengeStore, Held, Http, Outcomes, Switches}
  alias Lei.Payments.Mpp.{Challenge, Credential}
  alias Lei.Payments.Rails.{Mpp, Tempo}

  setup :verify_on_exit!

  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
  @hash "0xcc03711d01ade07b5b546263d81bbe620a32ac12fe540736e5d5f2780c152cf6"
  @memo "0xc09702f8182f5d94a23d75cc4c2e9835510fde10de3f5e6f20f2387b799f1ef0"
  @admin_token "test-admin-token-kill-switch"
  @webhook_secret "whsec_test_kill_switch"

  setup do
    Lei.RateLimiter.clear()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    saved =
      for k <- [
            :stripe_secret_key,
            :tempo_deposit_address,
            :tempo_poll_interval_ms,
            :stripe_webhook_secret
          ],
          do: {k, Application.get_env(:lei_service, k)}

    Application.put_env(:lei_service, :stripe_secret_key, "sk_test_" <> String.duplicate("x", 24))
    Application.put_env(:lei_service, :tempo_deposit_address, @deposit)
    Application.put_env(:lei_service, :tempo_poll_interval_ms, 0)
    Application.put_env(:lei_service, :stripe_webhook_secret, @webhook_secret)

    previous_admin = System.get_env("LEI_ADMIN_TOKEN")
    System.put_env("LEI_ADMIN_TOKEN", @admin_token)

    on_exit(fn ->
      for {k, v} <- saved do
        if v,
          do: Application.put_env(:lei_service, k, v),
          else: Application.delete_env(:lei_service, k)
      end

      if previous_admin,
        do: System.put_env("LEI_ADMIN_TOKEN", previous_admin),
        else: System.delete_env("LEI_ADMIN_TOKEN")
    end)

    {:ok, org} =
      Wallets.provision("0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)))

    %{org: org}
  end

  # -- helpers

  defp off(path),
    do: {:ok, _} = Switches.set(path, false, "test: #{path} off", "kill-switch-test")

  defp on(path), do: {:ok, _} = Switches.set(path, true, "test: #{path} on", "kill-switch-test")

  defp offer(org) do
    Http.challenge(conn(:get, "/v1/analyze"), org.id, 500,
      rails: [Mpp, Tempo],
      confirmed?: fn _ -> true end,
      memo: @memo
    )
  end

  defp challenge(conn, method) do
    conn
    |> get_resp_header("www-authenticate")
    |> Enum.map(fn h ->
      {:ok, c} = Challenge.from_header(h)
      c
    end)
    |> Enum.find(&(&1.method == method))
  end

  defp credential_header(challenge, payload) do
    Credential.to_header(%Credential{
      challenge: %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      },
      payload: payload,
      source: "did:pkh:eip155:42431:0x95b01240addf561daa31b76b1e8f89f8c4287917"
    })
  end

  defp tempo_credential(challenge),
    do: credential_header(challenge, %{"type" => "hash", "hash" => @hash})

  defp card_credential(challenge), do: credential_header(challenge, %{"spt" => "spt_test"})

  defp settle(header) do
    conn(:get, "/v1/analyze") |> put_req_header("authorization", header) |> Http.settle()
  end

  defp receipt do
    Path.join([__DIR__, "..", "..", "fixtures", "tempo", "memo_to_deposit.json"])
    |> File.read!()
    |> Poison.decode!()
  end

  defp settled_intent do
    %{
      "id" => "pi_kill_switch_held",
      "status" => "succeeded",
      "amount_received" => 50,
      "latest_charge" => %{
        "payment_method_details" => %{
          "crypto" => %{"buyer_address" => "0x95b0", "token_currency" => "usdc"}
        }
      }
    }
  end

  defp counts do
    Map.new(Outcomes.summary(), fn r -> {{r.rail, r.outcome, r.reason}, r.count} end)
  end

  defp endpoint(conn), do: LeiService.Endpoint.call(conn, LeiService.Endpoint.init([]))

  defp admin(method, path, body \\ nil, headers \\ [{"authorization", "Bearer #{@admin_token}"}]) do
    conn =
      if body,
        do:
          conn(method, path, Poison.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> endpoint()
  end

  # -- the switches themselves

  describe "switches" do
    test "every path is on until switched off" do
      for path <- ~w(mpp tempo acp pro_checkout), do: assert(Switches.enabled?(path))
    end

    test "the latest change wins, and every change is kept with who and why" do
      off("tempo")
      refute Switches.enabled?("tempo")
      on("tempo")
      assert Switches.enabled?("tempo")

      assert %{enabled: true, reason: "test: tempo on", actor: "kill-switch-test"} =
               Switches.state()["tempo"]

      assert length(Switches.history("tempo")) == 2
    end

    test "an unknown path or a change without a reason is refused" do
      assert {:error, :unknown_path} = Switches.set("paypal", false, "no such path", "t")
      assert {:error, :reason_required} = Switches.set("tempo", false, "", "t")
      assert Switches.enabled?("tempo")
    end
  end

  # -- machine rails

  describe "a machine rail switched off" do
    test "is not offered, and is counted as unavailable because it is switched off", %{org: org} do
      off("tempo")

      conn = offer(org)

      assert conn.status == 402
      assert challenge(conn, "tempo") == nil
      assert challenge(conn, "stripe") != nil
      assert counts()[{"tempo", "unavailable", "switched_off"}] == 1
    end

    test "with every rail off, the 402 says payment is unavailable", %{org: org} do
      off("tempo")
      off("mpp")

      conn = offer(org)

      assert conn.status == 402
      assert get_resp_header(conn, "www-authenticate") == []
      assert Poison.decode!(conn.resp_body)["payment"] == "unavailable"
    end

    test "refuses a card credential for a challenge issued before the switch, charging nothing",
         %{org: org} do
      card = offer(org) |> challenge("stripe")
      off("mpp")

      # No Stripe expectation: Mox fails the test if the card is charged.
      assert {:error, :rail_disabled} = settle(card_credential(card))

      assert Credits.balance(org.id) == 0
      assert counts()[{"mpp", "refused", "rail_disabled"}] == 1
      assert Held.list() == []
    end

    test "refuses a stablecoin credential without crediting it, and holds it", %{org: org} do
      tempo = offer(org) |> challenge("tempo")
      off("tempo")

      # No chain or Stripe expectation: nothing is verified while off.
      assert {:error, :rail_disabled} = settle(tempo_credential(tempo))

      assert Credits.balance(org.id) == 0
      assert counts()[{"tempo", "refused", "rail_disabled"}] == 1
      assert [%{challenge_id: id, rail: "tempo"}] = Held.list()
      assert id == tempo.id
    end

    test "a held payment survives the purge of expired challenges", %{org: org} do
      tempo = offer(org) |> challenge("tempo")
      off("tempo")
      settle(tempo_credential(tempo))

      ChallengeStore.purge_expired(DateTime.add(DateTime.utc_now(), 86_400, :second))

      assert [%{challenge_id: id}] = Held.list()
      assert id == tempo.id
    end
  end

  describe "a held stablecoin payment" do
    setup %{org: org} do
      tempo = offer(org) |> challenge("tempo")
      off("tempo")
      {:error, :rail_disabled} = settle(tempo_credential(tempo))
      %{tempo: tempo}
    end

    test "is credited on release, after its challenge has expired, with the rail still off",
         %{org: org} do
      # A challenge whose own expiry has passed -- as every held challenge's
      # has by the end of an incident. The expiry the rail checks is the one in
      # the issued challenge, not the database column.
      on("tempo")

      expired =
        Http.challenge(conn(:get, "/v1/analyze"), org.id, 500,
          rails: [Tempo],
          confirmed?: fn _ -> true end,
          memo: @memo,
          expires: DateTime.add(DateTime.utc_now(), -3600, :second)
        )
        |> challenge("tempo")

      off("tempo")
      assert {:error, :rail_disabled} = settle(tempo_credential(expired))

      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, @hash -> {:ok, receipt()} end)

      expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
        {:ok, settled_intent()}
      end)

      assert {:ok, %{rail: "tempo"}} = Held.release(expired.id)

      assert Credits.balance(org.id) == 500
      assert Enum.all?(Held.list(), &(&1.challenge_id != expired.id))
    end

    test "released twice credits once", %{org: org, tempo: tempo} do
      stub(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      stub(Lei.StripeMock, :create_crypto_verification_intent, fn _ -> {:ok, settled_intent()} end)

      assert {:ok, _} = Held.release(tempo.id)
      assert {:error, :not_held} = Held.release(tempo.id)

      assert Credits.balance(org.id) == 500
    end

    test "that is not held cannot be released", %{org: org} do
      card = offer(org) |> challenge("stripe")
      assert {:error, :not_held} = Held.release(card.id)
      assert {:error, :not_held} = Held.release("no-such-challenge")
    end
  end

  # -- human side

  describe "agent card checkout (acp) switched off" do
    test "opens no session" do
      off("acp")

      conn =
        conn(:post, "/acp/checkout", Poison.encode!(%{"sku" => "lei-credits-29000"}))
        |> put_req_header("content-type", "application/json")
        |> endpoint()

      assert conn.status == 503
      assert Poison.decode!(conn.resp_body)["error"] == "checkout unavailable"
    end

    test "completes no session opened before the switch, and charges nothing" do
      {:ok, session} = Lei.Acp.create_session("lei-credits-29000")
      off("acp")

      # No create_payment_intent expectation: Mox fails the test on a charge.
      conn =
        conn(
          :post,
          "/acp/checkout/#{session.id}/complete",
          Poison.encode!(%{"payment_method" => "pm_card_visa"})
        )
        |> put_req_header("content-type", "application/json")
        |> endpoint()

      assert conn.status == 503
      assert Repo.get!(Lei.AcpCheckoutSession, session.id).status == "open"
    end
  end

  describe "Pro checkout switched off" do
    test "sign-up starts no Stripe Checkout and creates no org" do
      off("pro_checkout")
      name = "Kill Switch Pro #{System.unique_integer([:positive])}"

      conn =
        conn(:post, "/signup", "name=#{URI.encode_www_form(name)}&tier=pro")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Lei.Web.Router.call(Lei.Web.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "temporarily unavailable"
      assert Repo.get_by(Org, name: name) == nil
    end

    test "a completed checkout is not applied, and Stripe is told to retry until it is back on" do
      {:ok, org} =
        ApiKeys.create_org("Kill Switch Webhook #{System.unique_integer([:positive])}",
          tier: "pro",
          status: "pending"
        )

      event = %{
        "id" => "evt_kill_switch_#{System.unique_integer([:positive])}",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "object" => "checkout.session",
            "status" => "complete",
            "payment_status" => "paid",
            "customer" => "cus_kill_switch",
            "subscription" => "sub_kill_switch",
            "metadata" => %{"org_id" => to_string(org.id)}
          }
        }
      }

      stub(Lei.StripeMock, :construct_webhook_event, fn payload, sig, secret ->
        Lei.Stripe.construct_webhook_event(payload, sig, secret)
      end)

      deliver = fn ->
        body = Poison.encode!(event)
        ts = System.system_time(:second)

        sig =
          :crypto.mac(:hmac, :sha256, @webhook_secret, "#{ts}.#{body}")
          |> Base.encode16(case: :lower)

        conn(:post, "/webhooks/stripe", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
        |> put_private(:raw_body, body)
        |> Lei.Web.Router.call(Lei.Web.Router.init([]))
      end

      off("pro_checkout")
      assert deliver.().status == 500
      assert Repo.get!(Org, org.id).status == "pending"

      # Stripe's retry, once it is back on, applies it: the refused delivery
      # was not recorded as processed.
      on("pro_checkout")
      assert deliver.().status == 200
      assert Repo.get!(Org, org.id).status == "active"
    end
  end

  describe "money going back" do
    test "is recorded whatever the switches say", %{org: org} do
      # Refunds and disputes are not payments taken. Switching a path off must
      # not stop the ledger hearing about money that has left.
      {:ok, _} =
        Lei.Payments.credit_settlement(org.id, %{
          credits: 15_000,
          rail: "tempo",
          settlement_ref: "pi_kill_switch_refund",
          usd_value_cents: 1_500
        })

      for path <- ~w(mpp tempo acp pro_checkout), do: off(path)

      assert Lei.Payments.Reversals.refund(%{
               "payment_intent" => "pi_kill_switch_refund",
               "amount_refunded" => 1_500,
               "currency" => "usd"
             }) == :applied
    end
  end

  # -- operator surface

  describe "the operator API" do
    test "switches a path off and on with the admin token in the header" do
      conn =
        admin(:post, "/admin/payments/switches/tempo", %{
          "enabled" => false,
          "reason" => "incident 42"
        })

      assert conn.status == 200

      assert %{"path" => "tempo", "enabled" => false, "reason" => "incident 42"} =
               Poison.decode!(conn.resp_body)

      refute Switches.enabled?("tempo")

      assert %{"tempo" => %{"enabled" => false}} =
               Poison.decode!(admin(:get, "/admin/payments/switches").resp_body)
    end

    test "refuses without the token, and refuses the token in the query string for a change" do
      body = %{"enabled" => false, "reason" => "no token"}

      assert admin(:post, "/admin/payments/switches/tempo", body, []).status == 401

      # A query-string token lands in access logs; acceptable for reading the
      # dashboard, not for switching payments off.
      assert admin(:post, "/admin/payments/switches/tempo?token=#{@admin_token}", body, []).status ==
               401

      assert Switches.enabled?("tempo")
    end

    test "requires a reason and a real path" do
      assert admin(:post, "/admin/payments/switches/tempo", %{"enabled" => false}).status == 422

      assert admin(:post, "/admin/payments/switches/paypal", %{
               "enabled" => false,
               "reason" => "x"
             }).status == 404

      assert Switches.enabled?("tempo")
    end
  end

  describe "metrics" do
    test "show each path's switch, 1 on and 0 off" do
      off("acp")
      body = Lei.Metrics.collect()

      assert body =~ ~s(lei_payment_switch_enabled{path="acp"} 0)
      assert body =~ ~s(lei_payment_switch_enabled{path="tempo"} 1)
    end

    test "count held payments waiting to be credited or refunded", %{org: org} do
      tempo = offer(org) |> challenge("tempo")
      off("tempo")
      settle(tempo_credential(tempo))

      assert Lei.Metrics.collect() =~ ~s(lei_payment_held{rail="tempo"} 1)
    end
  end
end
