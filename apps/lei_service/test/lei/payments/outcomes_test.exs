defmodule Lei.Payments.OutcomesTest do
  @moduledoc """
  Every payment attempt is counted by rail and outcome, and a refusal by why
  (#139, stage F).

  Before this, nothing recorded how the payment path was doing. A challenge
  that expired unanswered was purged within the hour, and a refused credential
  left only a log line. A rail whose settlements had fallen to zero while
  challenges were still being issued looked, from outside, exactly like a quiet
  day.

  Counts live in Postgres, in hourly buckets, so they survive the several
  deploys a day this service has; `/metrics` reports the last 24 hours.

  Driven through `Lei.Payments.Http`, which both paid routes call through
  `Lei.Payments.Gate`, with the MPP card rail and Stripe mocked as in
  `Lei.Payments.HttpTest`.
  """
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Lei.{Repo, Wallets}
  alias Lei.Payments.{Http, Outcomes}
  alias Lei.Payments.Mpp.{Challenge, Credential}

  setup :verify_on_exit!

  setup do
    Lei.RateLimiter.clear()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)

    %{org: org}
  end

  defp issue_challenge(org) do
    conn = Http.challenge(conn(:get, "/v1/analyze"), org.id, 15_000)
    [header] = get_resp_header(conn, "www-authenticate")
    {:ok, challenge} = Challenge.from_header(header)
    challenge
  end

  defp credential_header(challenge, overrides \\ %{}) do
    echoed =
      %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      }
      |> Map.merge(overrides)

    Credential.to_header(%Credential{
      challenge: echoed,
      payload: %{"spt" => "spt_test"},
      source: "acct_agent"
    })
  end

  defp with_credential(header) do
    conn(:get, "/v1/analyze") |> put_req_header("authorization", header)
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "pi_outcomes_#{System.unique_integer([:positive])}",
        "status" => "succeeded",
        "amount" => 1500,
        "amount_received" => 1500,
        "currency" => "usd"
      },
      overrides
    )
  end

  # {rail, outcome, reason} => count, over the last 24 hours.
  defp counts do
    Map.new(Outcomes.summary(), fn row -> {{row.rail, row.outcome, row.reason}, row.count} end)
  end

  describe "a challenge" do
    test "issued is counted against its rail", %{org: org} do
      issue_challenge(org)
      issue_challenge(org)

      assert counts()[{"mpp", "issued", ""}] == 2
    end

    test "a rail that cannot offer one is counted as unavailable, with why", %{org: org} do
      previous = Application.get_env(:lei_service, :stripe_profile_id)
      Application.delete_env(:lei_service, :stripe_profile_id)
      on_exit(fn -> Application.put_env(:lei_service, :stripe_profile_id, previous) end)

      assert Http.challenge(conn(:get, "/v1/analyze"), org.id, 15_000).status == 402

      # Each rail that declined is counted with its own reason; the test
      # configuration also has tempo, unconfigured here.
      assert counts()[{"mpp", "unavailable", "no_stripe_profile"}] == 1
      refute Map.has_key?(counts(), {"mpp", "issued", ""})
    end
  end

  describe "a credential" do
    test "that settles is counted as presented and settled", %{org: org} do
      challenge = issue_challenge(org)
      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ -> {:ok, intent()} end)

      assert {:ok, _, _} = Http.settle(with_credential(credential_header(challenge)))

      assert counts()[{"mpp", "presented", ""}] == 1
      assert counts()[{"mpp", "settled", ""}] == 1
    end

    test "presented again after settling is a retry, not a second settlement", %{org: org} do
      # Conversion is challenges settled over challenges issued. A retried
      # credential counted as another settlement would inflate it.
      challenge = issue_challenge(org)
      header = credential_header(challenge)
      expect(Lei.StripeMock, :confirm_shared_payment_token, 2, fn _ -> {:ok, intent()} end)

      assert {:ok, _, _} = Http.settle(with_credential(header))
      assert {:ok, _, _} = Http.settle(with_credential(header))

      assert counts()[{"mpp", "presented", ""}] == 2
      assert counts()[{"mpp", "settled", ""}] == 1
      assert counts()[{"mpp", "settled", "retry"}] == 1
    end

    test "for a challenge we never issued is refused with no rail to name", %{org: org} do
      real = issue_challenge(org)
      forged = %{real | id: "never-issued-" <> real.id}

      assert {:error, :unknown_challenge} =
               Http.settle(with_credential(credential_header(forged)))

      assert counts()[{"unknown", "presented", ""}] == 1
      assert counts()[{"unknown", "refused", "unknown_challenge"}] == 1
    end

    test "echoing a different price is refused on its rail, as challenge_mismatch", %{org: org} do
      challenge = issue_challenge(org)

      tampered =
        credential_header(challenge, %{
          "request" => Challenge.encode_json(%{"amount" => "1", "credits" => 15_000})
        })

      assert {:error, :challenge_mismatch} = Http.settle(with_credential(tampered))

      assert counts()[{"mpp", "refused", "challenge_mismatch"}] == 1
    end

    test "that is malformed is refused as malformed_credential" do
      assert {:error, :malformed_credential} =
               Http.settle(with_credential("Payment !!!not-base64!!!"))

      assert counts()[{"unknown", "refused", "malformed_credential"}] == 1
    end

    test "whose payment did not settle is refused by the reason's name, not its detail", %{
      org: org
    } do
      # {:payment_not_settled, "processing"} is counted as payment_not_settled.
      # A reason carrying Stripe's detail as a label would make a series per
      # distinct value, which an attacker controls.
      challenge = issue_challenge(org)

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:ok, intent(%{"status" => "processing"})}
      end)

      assert {:error, {:payment_not_settled, "processing"}} =
               Http.settle(with_credential(credential_header(challenge)))

      assert counts()[{"mpp", "refused", "payment_not_settled"}] == 1
    end

    test "with no credential is not counted at all" do
      assert :no_credential = Http.settle(conn(:get, "/v1/analyze"))

      assert counts() == %{}
    end
  end

  describe "rate limiting" do
    setup do
      original = Application.get_env(:lei_service, :rate_limits)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:lei_service, :rate_limits)
          value -> Application.put_env(:lei_service, :rate_limits, value)
        end
      end)

      Application.put_env(:lei_service, :rate_limits, %{
        free: 60,
        pro: 600,
        payment_challenge: 1,
        payment_settle: 1
      })

      :ok
    end

    test "a limited challenge or settle is counted, since a spike is an attack", %{org: org} do
      challenge = issue_challenge(org)
      assert Http.challenge(conn(:get, "/v1/analyze"), org.id, 15_000).status == 429

      header = credential_header(challenge)
      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ -> {:ok, intent()} end)
      assert {:ok, _, _} = Http.settle(with_credential(header))
      assert {:rate_limited, _} = Http.settle(with_credential(header))

      assert counts()[{"unknown", "rate_limited", "payment_challenge"}] == 1
      assert counts()[{"unknown", "rate_limited", "payment_settle"}] == 1
    end
  end

  describe "the window" do
    test "reports the last 24 hours and nothing older" do
      now = DateTime.utc_now()

      Outcomes.record("mpp", "issued", nil, now)
      Outcomes.record("mpp", "issued", nil, DateTime.add(now, -23 * 3600, :second))
      Outcomes.record("mpp", "issued", nil, DateTime.add(now, -25 * 3600, :second))

      assert counts()[{"mpp", "issued", ""}] == 2
    end

    test "counts in one hour share a row" do
      now = DateTime.utc_now()
      for _ <- 1..3, do: Outcomes.record("tempo", "issued", nil, now)

      assert Repo.aggregate(Outcomes.Bucket, :count, :id) == 1
      assert counts()[{"tempo", "issued", ""}] == 3
    end

    test "buckets older than 30 days are pruned, newer ones kept" do
      now = DateTime.utc_now()
      Outcomes.record("mpp", "issued", nil, DateTime.add(now, -31 * 86_400, :second))
      Outcomes.record("mpp", "issued", nil, DateTime.add(now, -29 * 86_400, :second))

      assert Outcomes.prune(now) == 1
      assert Repo.aggregate(Outcomes.Bucket, :count, :id) == 1
    end
  end

  describe "metrics" do
    test "list every configured rail at zero, so none yet differs from not collected" do
      body = Lei.Metrics.collect()

      for outcome <- ~w(issued presented settled refused) do
        assert body =~
                 ~s(lei_payment_outcomes{rail="mpp",outcome="#{outcome}",reason="",window="24h"} 0)
      end
    end

    test "report the counts by rail, outcome and reason", %{org: org} do
      real = issue_challenge(org)
      Http.settle(with_credential(credential_header(%{real | id: "forged"})))

      body = Lei.Metrics.collect()

      assert body =~
               ~s(lei_payment_outcomes{rail="mpp",outcome="issued",reason="",window="24h"} 1)

      assert body =~
               ~s(lei_payment_outcomes{rail="unknown",outcome="refused",reason="unknown_challenge",window="24h"} 1)
    end
  end
end
