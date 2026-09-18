defmodule Lei.Repo.Migrations.AddProbeExcludedToStripeReconciliationRuns do
  use Ecto.Migration

  # Verification probes are real sandbox payments made against production to
  # prove the rails work. Stripe received them and the ledger deliberately
  # never credited them, so they read as "received, never credited" on every
  # run, forever -- and a check that is permanently red is one nobody reads.
  #
  # They are excluded from the discrepancy list by naming convention and
  # counted here instead. Recorded per run rather than derived, so a past
  # run's numbers still add up after the convention changes.
  #
  # Defaults to 0 so existing rows read as "excluded nothing", which is what
  # they did.
  def change do
    alter table(:stripe_reconciliation_runs) do
      add(:probe_excluded, :integer, null: false, default: 0)
    end
  end
end
