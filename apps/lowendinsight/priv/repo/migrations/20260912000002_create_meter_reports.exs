defmodule Lei.Repo.Migrations.CreateMeterReports do
  use Ecto.Migration

  def change do
    create table(:meter_reports) do
      add(:org_id, references(:orgs, on_delete: :restrict), null: false)
      add(:analysis_usage_id, :bigint)
      add(:identifier, :string, null: false)
      add(:units, :bigint, null: false)
      add(:status, :string, null: false)
      add(:error, :text)

      timestamps(updated_at: false)
    end

    # The same idempotency boundary as credit_entries.external_ref: the meter
    # identifier is what Stripe deduplicates on, so it is what we deduplicate
    # on too.
    create(unique_index(:meter_reports, [:identifier]))
    create(index(:meter_reports, [:org_id]))
    create(index(:meter_reports, [:status]))

    # Not a column on credit_entries, deliberately. The ledger is append-only,
    # and stamping an outcome onto a debit after the fact is a mutation --
    # ADR-002 rejects a mutable balance for the same reason. This records what
    # happened next, alongside, rather than editing what already happened.
  end
end
