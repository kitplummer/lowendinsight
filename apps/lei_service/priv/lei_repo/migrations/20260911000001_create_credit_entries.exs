defmodule Lei.Repo.Migrations.CreateCreditEntries do
  use Ecto.Migration

  def change do
    create table(:credit_entries) do
      add :org_id, references(:orgs, on_delete: :restrict), null: false
      add :delta, :bigint, null: false
      add :reason, :string, null: false
      add :external_ref, :string
      add :usd_value_cents, :integer
      add :jurisdiction, :string
      add :metadata, :map, default: %{}

      # Entries are never modified, so there is no updated_at to maintain.
      timestamps(updated_at: false)
    end

    create index(:credit_entries, [:org_id])

    # The idempotency boundary. A replayed Stripe webhook or a resubmitted x402
    # payment proof carries the same external_ref and is refused here -- by the
    # database, not by a pre-check SELECT, which two concurrent writers both
    # pass. Entries without a ref (manual adjustments, debits) are unconstrained.
    create unique_index(:credit_entries, [:external_ref], where: "external_ref IS NOT NULL")

    # orgs are deleted with :restrict rather than :delete_all above: financial
    # history should outlive the convenience of a cascading delete.
  end
end
