defmodule Lei.Repo.Migrations.ProActiveRequiresCustomer do
  use Ecto.Migration

  # An active Pro organisation must be billable.
  #
  # Three code paths decided what "pro" meant and disagreed: two served it as
  # unlimited, and the one that reports usage to Stripe required a
  # stripe_customer_id and silently did nothing without one. The gap between
  # those definitions is unbounded free service that nothing reports.
  #
  # The changesets now refuse to build the row, but a constraint is what makes
  # the state unrepresentable: it also covers an operator editing the database
  # directly, a future code path nobody thought to check, and anything that
  # writes through Repo without a changeset.
  #
  # Deliberately not validated as NOT VALID. Production holds no such rows
  # (scripts/ops/unbilled-pro-orgs.sh, 2026-09-18), so this checks the existing
  # table and fails the migration if that ever stops being true -- which is the
  # answer we would want, before the deploy rather than after it.
  #
  # Pending and suspended Pro orgs are unconstrained: neither is served, and
  # suspension has to stay available as the response to a row that is wrong.
  #
  # Prepaid and wallet-identified orgs are exempt, because they are never
  # served on the pro path: Lei.UsageTracker.allowance/3 tests prepaid? before
  # it tests the tier, so their gate is the credit balance and the tier column
  # is inert. Constraining them would forbid a harmless row and, worse, state
  # an invariant the serving code does not actually hold.
  def up do
    create(
      constraint(:orgs, :orgs_pro_active_requires_customer,
        check: """
        NOT (tier = 'pro' AND status = 'active'
             AND prepaid = false AND wallet_address IS NULL
             AND (stripe_customer_id IS NULL OR stripe_customer_id = ''))
        """
      )
    )
  end

  def down do
    drop(constraint(:orgs, :orgs_pro_active_requires_customer))
  end
end
