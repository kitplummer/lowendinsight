defmodule Lei.Repo.Migrations.CreateStripeReconciliationRuns do
  use Ecto.Migration

  # Each hourly comparison of the ledger's purchases with Stripe's payments
  # (#139). Kept, so "when did this start disagreeing" has an answer, and so a
  # run that stopped happening shows as an old latest run rather than nothing.
  def change do
    create table(:stripe_reconciliation_runs) do
      add(:window_start, :utc_datetime, null: false)
      # ok | discrepancies | failed
      add(:status, :string, null: false)
      add(:ledger_purchases, :integer)
      add(:stripe_purchases, :integer)
      add(:discrepancy_count, :integer)
      # The first 100, enough to start an investigation without an unbounded row.
      add(:discrepancies, {:array, :map}, null: false, default: [])
      add(:error, :text)

      timestamps(updated_at: false)
    end

    create(index(:stripe_reconciliation_runs, [:inserted_at]))
  end
end
