defmodule Lei.BetaBillingTest do
  @moduledoc """
  Beta: analysis is free, and the limits are the free tier's.

  The point of beta is data and exercise -- build up the cache, run the flows,
  find out what scaling costs -- so usage is still recorded on every request.
  What stops is charging: no ledger debit, no Stripe meter event, and no org
  refused for want of credits.

  The mode is explicit and published rather than a set of rates quietly changed
  to zero, because "billing silently went free" and "we are in beta" would
  otherwise be the same observable state. `lei_billing_mode` is on /metrics and
  the monitor asserts which mode it expects, the same way it does for
  `lei_stripe_mode` -- so beta left switched on after launch is a red run rather
  than a month of unbilled service.
  """
  use ExUnit.Case, async: false

  alias Lei.{Billing, Credits, Repo, UsageTracker, Wallets}

  # A rail whose minimum differs from the configured beta amount. Without one,
  # the configured 500 and Tempo's 500 coincide and `max` and `min` over them
  # return the same number -- which is how the first version of
  # beta-challenge-below-a-rail-floor passed with the bug reintroduced.
  defmodule HigherFloorRail do
    def minimum_purchase_credits, do: 1200
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    saved = Application.get_env(:lei_service, :billing_mode)
    on_exit(fn -> Application.put_env(:lei_service, :billing_mode, saved) end)

    {:ok, org} =
      Wallets.provision("0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)))

    %{org: org}
  end

  defp beta!, do: Application.put_env(:lei_service, :billing_mode, :beta)
  defp charging!, do: Application.put_env(:lei_service, :billing_mode, :charge)

  describe "the mode itself" do
    test "defaults to charging, so free service is never the accident" do
      Application.delete_env(:lei_service, :billing_mode)

      assert Billing.mode() == :charge
      refute Billing.beta?()
    end

    test "beta is a mode, not a rate set to zero" do
      beta!()
      assert Billing.mode() == :beta
      assert Billing.beta?()
    end

    test "an unrecognised mode is charging, not free" do
      # A typo in a deploy variable must not hand out free analyses.
      Application.put_env(:lei_service, :billing_mode, :betaa)
      assert Billing.mode() == :charge
    end
  end

  describe "nothing is charged" do
    test "an analysis costs no credits" do
      beta!()
      assert Credits.cost_in_credits(0, 10) == 0
      assert Credits.cost_in_credits(10, 10) == 0

      charging!()
      assert Credits.cost_in_credits(0, 10) == 500
    end

    test "admission writes no ledger entry", %{org: org} do
      beta!()
      {:ok, _usage} = UsageTracker.admit_usage(org.id, nil, 2, 3, 0)

      assert Credits.balance(org.id) == 0,
             "beta debited the ledger, so an org is being charged"

      assert Credits.entries(org.id) == [],
             "beta wrote a ledger entry, so the balance is a coincidence"
    end

    test "usage is still recorded -- that is the point of beta", %{org: org} do
      beta!()
      {:ok, _} = UsageTracker.admit_usage(org.id, nil, 2, 3, 0)

      usage = UsageTracker.get_current_usage(org.id)
      assert usage.cache_hits == 2
      assert usage.cache_misses == 3

      # A Decimal, so compared as one -- `== 0` is false for Decimal.new(0) and
      # would have passed for any cost at all.
      assert Decimal.equal?(usage.total_cost_cents, 0),
             "beta recorded a cost of #{usage.total_cost_cents}, which reconciliation would bill"
    end
  end

  describe "an org is not refused for money" do
    test "a credit-funded org with an empty balance is admitted", %{org: org} do
      # Under charging this is the insufficient_credits path. In beta there is
      # nothing to be insufficient for.
      # The ledger validates `reason` against a fixed list, so these are real
      # reasons rather than invented ones.
      {:ok, _} = Credits.grant(org.id, 10, "purchase:stripe", external_ref: "beta-#{org.id}")
      {:ok, _} = Credits.debit(org.id, 10, "debit:analysis", external_ref: "spend-#{org.id}")
      assert Credits.balance(org.id) == 0

      beta!()
      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 0, 1, 0)
    end

    test "a credit-funded org gets the default allowance, not zero", %{org: org} do
      # Wallets.provision/1 and the ACP path both set free_tier_analyses_limit
      # to 0 with prepaid: true, because a credit-funded org buys analyses
      # instead of receiving an allowance. Carried into beta unchanged, that is
      # "free, and you get none" -- every wallet and agent org refused with
      # used: 0, limit: 0. Found by this test, not by reasoning.
      assert org.free_tier_analyses_limit == 0,
             "the fixture no longer reproduces the zero-limit case this guards"

      beta!()
      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 0, 5, 0)
    end

    test "the free tier's limit still applies", %{org: org} do
      # Free, but not unlimited: the allowance is what bounds what beta costs us.
      beta!()
      org |> Ecto.Changeset.change(free_tier_analyses_limit: 3) |> Repo.update!()

      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 0, 3, 0)

      assert {:error, {:quota_exceeded, info}} =
               UsageTracker.admit_usage(org.id, nil, 0, 1, 0)

      assert info.limit == 3
    end

    test "a pro org is held to the same limit, not served without one", %{org: org} do
      # Under charging, a billable Pro org is unlimited. In beta nobody is
      # billable, so unlimited would mean unbounded free service.
      beta!()

      org
      |> Ecto.Changeset.change(
        tier: "pro",
        stripe_customer_id: "cus_beta_test",
        free_tier_analyses_limit: 2
      )
      |> Repo.update!()

      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 0, 2, 0)
      assert {:error, {:quota_exceeded, _}} = UsageTracker.admit_usage(org.id, nil, 0, 1, 0)
    end
  end

  describe "what an agent is asked for" do
    # An agent has no concept of a beta; it has a 402 handler. Charging it the
    # full $15 block for analysis that is free would be taking money for
    # nothing, and serving it for nothing would be an allowance per attacker --
    # acp_checkout_session.ex already records why there is no free agent SKU:
    # "an org costs nothing to create here, so any allowance per org is an
    # allowance per attacker".
    #
    # So during beta the challenge is the smallest amount the rails can move.
    # It buys identity rather than analysis.
    test "the challenge is the rails' floor, not the usual block" do
      charging!()
      assert Lei.Payments.Gate.top_up_credits(0, 0) == 15_000

      beta!()

      assert Lei.Payments.Gate.top_up_credits(0, 0) == 500,
             "an agent is asked for the full block while analysis is free"
    end

    test "it is never below what a rail will settle" do
      # Tempo's minimum is $0.50 because Stripe refuses a crypto PaymentIntent
      # below that (#144). A challenge under a rail's own floor is one the agent
      # cannot pay, so it would be refused, pay nothing, and retry forever.
      beta!()
      floor = Lei.Payments.Gate.top_up_credits(0, 0)

      for rail <- Application.get_env(:lei_service, :payment_rails, []) do
        case rail.minimum_purchase_credits() do
          nil ->
            :ok

          minimum ->
            assert floor >= minimum,
                   "#{inspect(rail)} will not settle #{floor} credits; its minimum is #{minimum}"
        end
      end
    end

    test "the floor follows a rail that declares a higher minimum" do
      # The mechanism, not the number. Asserting only that the floor is >= every
      # rail's minimum passes whether the rails are consulted or ignored, as
      # long as the configured amount happens to be large enough.
      beta!()
      saved = Application.get_env(:lei_service, :payment_rails)
      on_exit(fn -> Application.put_env(:lei_service, :payment_rails, saved) end)

      Application.put_env(:lei_service, :payment_rails, [HigherFloorRail])

      assert Lei.Payments.Gate.top_up_credits(0, 0) == 1200,
             "the challenge ignores a rail that will not settle the configured amount"
    end

    test "a request needing more than the floor still asks for the shortfall" do
      # The floor is a minimum, not a cap: an SBOM naming hundreds of uncached
      # repositories costs more than one block, and asking for less would admit
      # a request the agent cannot cover.
      beta!()

      assert Lei.Payments.Gate.top_up_credits(0, 900) == 900
      assert Lei.Payments.Gate.top_up_credits(200, 900) == 700
    end
  end

  describe "what a user is told" do
    test "the terms page states the mode the deployment is actually in" do
      beta!()
      conn = :get |> Plug.Test.conn("/terms") |> LeiService.Endpoint.call([])

      assert conn.status == 200
      assert conn.resp_body =~ "Nothing is charged today"
      # The two statements that must be there whatever the mode.
      assert conn.resp_body =~ "no warranty of any kind"
      assert conn.resp_body =~ "at your own risk"
      assert conn.resp_body =~ "30 days"

      charging!()
      conn = :get |> Plug.Test.conn("/terms") |> LeiService.Endpoint.call([])
      assert conn.resp_body =~ "Beta has ended"
    end

    test "llms.txt says analysis is free while it is" do
      beta!()
      conn = :get |> Plug.Test.conn("/llms.txt") |> LeiService.Endpoint.call([])

      assert conn.status == 200

      assert conn.resp_body =~ "analysis is free",
             "agents are quoted a price the ledger does not charge"

      # The rates stay published: when beta ends the numbers must not appear
      # from nowhere.
      assert conn.resp_body =~ "One credit is $0.001"

      # And the amount an account-less agent is actually asked for, because
      # /llms.txt saying analysis is free while the gate asks for $15 is exactly
      # the drift the agent guide exists to prevent.
      assert conn.resp_body =~ "500 credits ($0.50)",
             "agents are not told what the challenge will actually ask for"

      charging!()
      conn = :get |> Plug.Test.conn("/llms.txt") |> LeiService.Endpoint.call([])
      refute conn.resp_body =~ "analysis is free"
    end
  end

  describe "the mode is visible" do
    test "metrics publish which mode is in force" do
      beta!()
      assert Lei.Metrics.collect() =~ ~s(lei_billing_mode{mode="beta"} 1)

      charging!()
      assert Lei.Metrics.collect() =~ ~s(lei_billing_mode{mode="charge"} 1)
    end

    test "the monitor asserts the mode it expects" do
      monitor = File.read!(Path.expand("../../../../.github/workflows/monitor.yml", __DIR__))

      assert monitor =~ "lei_billing_mode",
             "nothing notices beta being left on after launch"

      assert monitor =~ "LEI_EXPECTED_BILLING_MODE",
             "the expected mode is not configurable, so the check cannot survive launch"
    end
  end
end
