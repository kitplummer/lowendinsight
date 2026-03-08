defmodule Lei.Repo.Migrations.CreateAcpCheckoutSessions do
  use Ecto.Migration

  def change do
    create table(:acp_checkout_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :sku, :string, null: false
      add :status, :string, default: "open", null: false
      add :customer_name, :string
      add :amount_cents, :integer, null: false
      add :currency, :string, default: "usd", null: false
      add :stripe_payment_intent_id, :string
      add :metadata, :map, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      add :org_id, references(:orgs, on_delete: :nilify_all)

      timestamps()
    end

    create index(:acp_checkout_sessions, [:status])
    create index(:acp_checkout_sessions, [:org_id])
  end
end
