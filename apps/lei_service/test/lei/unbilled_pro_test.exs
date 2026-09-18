defmodule Lei.UnbilledProTest do
  @moduledoc """
  A Pro organisation is served unlimited analysis only while it can be billed.

  Three places decided what "pro" meant, and they disagreed:

    * `allowance/3` -- pro means unlimited
    * `check_free_tier_quota/1` -- pro means unlimited
    * `report_meter_event/3` -- pro **with a `stripe_customer_id`** means bill,
      and anything else silently returns `:ok`

  The gap between those definitions is unbounded free service. An org that is
  `tier: "pro"` and `status: "active"` with no customer id is served without
  limit and never reported to Stripe, and nothing anywhere says so.

  Production has none (`scripts/ops/unbilled-pro-orgs.sh`, 2026-09-18), and the
  two paths that made them -- ACP's `lei-pro-monthly` SKU, and
  `/signup/success` activating without asking Stripe -- were both closed on
  2026-09-14. So this is a latent hole rather than a leak, and the response is
  to make the state unrepresentable rather than to watch for it:

    1. the database refuses the row
    2. both changesets refuse to build it
    3. `billable_pro?/1` is the single definition the serving paths consult
    4. `lei_unbilled_pro_orgs` counts any that exist anyway

  The fourth matters because the first three are only as good as their
  reachability: a row that predates the constraint, or an operator editing the
  database directly, still has to be visible.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.{ApiKeys, Org, Repo, UsageTracker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp unique(name), do: "#{name} #{System.unique_integer([:positive])}"

  # A row the constraint would refuse. Dropping the constraint inside the test
  # transaction is rolled back with everything else, and is the only way to
  # exercise the serving paths against a row that predates it -- which is
  # exactly the case the gauge and the allowance fallback exist for.
  defp legacy_unbilled_pro!(name) do
    Repo.query!("ALTER TABLE orgs DROP CONSTRAINT orgs_pro_active_requires_customer")

    {:ok, org} = ApiKeys.find_or_create_org(unique(name), tier: "free", status: "active")

    org
    |> Ecto.Changeset.change(tier: "pro", stripe_customer_id: nil)
    |> Repo.update!()
  end

  describe "the database refuses the row" do
    test "an active pro org with no customer id cannot be written, even outside a changeset" do
      {:ok, org} = ApiKeys.find_or_create_org(unique("Direct"), tier: "free", status: "active")

      assert_raise Postgrex.Error, ~r/orgs_pro_active_requires_customer/, fn ->
        Repo.query!("UPDATE orgs SET tier = 'pro' WHERE id = $1", [org.id])
      end
    end

    test "the same row with a customer id is allowed" do
      {:ok, org} = ApiKeys.find_or_create_org(unique("Direct OK"), tier: "free", status: "active")

      assert {:ok, _} =
               Repo.query(
                 "UPDATE orgs SET tier = 'pro', stripe_customer_id = 'cus_ok' WHERE id = $1",
                 [org.id]
               )
    end
  end

  describe "the changesets refuse to build it" do
    test "Org.changeset/2 will not create an active pro org without a customer" do
      changeset = Org.changeset(%Org{}, %{name: unique("New Pro"), tier: "pro", status: "active"})

      refute changeset.valid?
      assert errors_on(changeset)[:stripe_customer_id]
    end

    test "Org.stripe_changeset/2 will not activate a pro org without a customer" do
      {:ok, org} =
        ApiKeys.find_or_create_org(unique("Pending Pro"), tier: "pro", status: "pending")

      changeset = Org.stripe_changeset(org, %{status: "active"})

      refute changeset.valid?
      assert errors_on(changeset)[:stripe_customer_id]
    end

    test "activating with the customer id in the same change is allowed" do
      {:ok, org} =
        ApiKeys.find_or_create_org(unique("Paying Pro"), tier: "pro", status: "pending")

      changeset =
        Org.stripe_changeset(org, %{status: "active", stripe_customer_id: "cus_paid"})

      assert changeset.valid?
      assert {:ok, %Org{status: "active"}} = Repo.update(changeset)
    end

    # Suspension must keep working for a row that is already wrong, or the
    # invariant would make the one safe response to it impossible.
    test "a pro org with no customer can still be suspended" do
      org = legacy_unbilled_pro!("Legacy Suspend")

      changeset = Org.stripe_changeset(org, %{status: "suspended"})

      assert changeset.valid?
      assert {:ok, %Org{status: "suspended"}} = Repo.update(changeset)
    end

    # Their gate is the credit balance, tested before the tier is looked at,
    # so the tier column is inert for them and the rule must not apply --
    # Lei.WalletsTest asserts precedence with exactly such an org.
    test "a prepaid org may be pro and active without a customer" do
      changeset =
        Org.changeset(%Org{prepaid: true}, %{
          name: unique("Prepaid Pro"),
          tier: "pro",
          status: "active"
        })

      assert changeset.valid?
    end

    test "a wallet org may be pro and active without a customer" do
      {:ok, org} = Lei.Wallets.provision("0x" <> String.duplicate("a", 40))

      assert {:ok, _} =
               org |> Ecto.Changeset.change(tier: "pro", status: "active") |> Repo.update()
    end

    test "a free org needs no customer id to be active" do
      changeset = Org.changeset(%Org{}, %{name: unique("Free"), tier: "free", status: "active"})
      assert changeset.valid?
    end
  end

  describe "one definition of billable" do
    test "a pro org with a customer id is billable" do
      assert UsageTracker.billable_pro?(%Org{tier: "pro", stripe_customer_id: "cus_x"})
    end

    test "a pro org without one is not" do
      refute UsageTracker.billable_pro?(%Org{tier: "pro", stripe_customer_id: nil})
      refute UsageTracker.billable_pro?(%Org{tier: "pro", stripe_customer_id: ""})
    end

    test "a free org is not billable as pro, whatever else it holds" do
      refute UsageTracker.billable_pro?(%Org{tier: "free", stripe_customer_id: "cus_x"})
    end
  end

  describe "serving follows that definition" do
    test "a billable pro org is unlimited, well past the free limit" do
      {:ok, org} = ApiKeys.find_or_create_org(unique("Billable"), tier: "free", status: "active")

      org =
        org
        |> Ecto.Changeset.change(
          tier: "pro",
          stripe_customer_id: "cus_billable",
          free_tier_analyses_limit: 1
        )
        |> Repo.update!()

      assert {:ok, :unlimited} = UsageTracker.check_free_tier_quota(org.id)
    end

    # The fallback, not a refusal: a customer who genuinely paid should keep
    # working rather than be locked out by our own bookkeeping. Bounded, and
    # counted on /metrics while it lasts.
    test "an unbillable pro org falls back to the free tier rather than unlimited" do
      org = legacy_unbilled_pro!("Legacy Quota")

      org
      |> Ecto.Changeset.change(free_tier_analyses_limit: 1)
      |> Repo.update!()

      refute UsageTracker.check_free_tier_quota(org.id) == {:ok, :unlimited}

      {:ok, _} = UsageTracker.record_usage(org.id, nil, 1, 0)

      assert {:error, :quota_exceeded, _} = UsageTracker.check_free_tier_quota(org.id)
    end

    # admit_usage/5 is the gate; record_usage/4 only writes what already
    # happened. Asserted here because allowance/3 is reached from the former
    # and nowhere else, so this is the path that actually refuses work.
    test "admission for an unbillable pro org is refused once the free limit is spent" do
      org = legacy_unbilled_pro!("Legacy Admit")

      org
      |> Ecto.Changeset.change(free_tier_analyses_limit: 1)
      |> Repo.update!()

      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 1, 0, 0)

      assert {:error, {:quota_exceeded, _}} = UsageTracker.admit_usage(org.id, nil, 1, 0, 0)
    end

    test "a billable pro org is admitted well past the free limit" do
      {:ok, org} = ApiKeys.find_or_create_org(unique("Admit Pro"), tier: "free", status: "active")

      org =
        org
        |> Ecto.Changeset.change(
          tier: "pro",
          stripe_customer_id: "cus_admit",
          free_tier_analyses_limit: 1
        )
        |> Repo.update!()

      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 1, 0, 0)
      assert {:ok, _} = UsageTracker.admit_usage(org.id, nil, 5, 0, 0)
    end
  end

  describe "any that exist anyway are counted" do
    test "the gauge is zero when there are none" do
      assert Lei.Metrics.collect() =~ ~s(lei_unbilled_pro_orgs{state="no_customer"} 0)
    end

    test "a legacy row is counted" do
      legacy_unbilled_pro!("Legacy Gauge")

      assert Lei.Metrics.collect() =~ ~s(lei_unbilled_pro_orgs{state="no_customer"} 1)
    end

    test "a pro org missing only its subscription is counted separately" do
      Repo.query!("ALTER TABLE orgs DROP CONSTRAINT orgs_pro_active_requires_customer")

      {:ok, org} = ApiKeys.find_or_create_org(unique("No Sub"), tier: "free", status: "active")

      org
      |> Ecto.Changeset.change(
        tier: "pro",
        stripe_customer_id: "cus_nosub",
        stripe_subscription_id: nil
      )
      |> Repo.update!()

      metrics = Lei.Metrics.collect()

      assert metrics =~ ~s(lei_unbilled_pro_orgs{state="no_subscription"} 1)
      # It has a customer, so it is billable and not counted as that.
      assert metrics =~ ~s(lei_unbilled_pro_orgs{state="no_customer"} 0)
    end

    test "a pending pro org is not counted: it is not being served" do
      {:ok, _org} =
        ApiKeys.find_or_create_org(unique("Pending"), tier: "pro", status: "pending")

      assert Lei.Metrics.collect() =~ ~s(lei_unbilled_pro_orgs{state="no_customer"} 0)
    end
  end

  describe "the shape of the bug is gone" do
    # ApiKeys.activate_org/1 activated an org with no reference to Stripe at
    # all. It had no production callers: its last role was as the *replacement*
    # in the mutation guarding GET /signup/success, so the function survived as
    # the literal shape of a bug that shipped. Deleted, so it cannot be called
    # back into service by someone who finds it and assumes it is the way to
    # activate an org.
    test "there is no way to activate an org without going through Stripe" do
      refute function_exported?(ApiKeys, :activate_org, 1),
             "ApiKeys.activate_org/1 is back; activation must go through Lei.Signup or the webhook"
    end
  end

  # Counting the rows rather than trusting the gauge's own arithmetic.
  defp unbilled_count do
    Repo.aggregate(
      from(o in Org,
        where: o.tier == "pro" and o.status == "active" and is_nil(o.stripe_customer_id)
      ),
      :count,
      :id
    )
  end

  test "the gauge reports what the table holds" do
    legacy_unbilled_pro!("Legacy Agreement")

    assert unbilled_count() == 1
    assert Lei.Metrics.collect() =~ ~s(lei_unbilled_pro_orgs{state="no_customer"} 1)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
