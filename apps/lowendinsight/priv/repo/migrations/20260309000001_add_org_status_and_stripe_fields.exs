defmodule Lei.Repo.Migrations.AddOrgStatusAndStripeFields do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :status, :string, default: "pending", null: false
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
    end

    # Backfill existing orgs to "active"
    execute "UPDATE orgs SET status = 'active' WHERE status = 'pending'", ""

    create index(:orgs, [:status])
    create index(:orgs, [:stripe_customer_id])
  end
end
