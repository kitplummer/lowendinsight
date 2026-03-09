defmodule Lei.Repo.Migrations.AddOrgBillingFields do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :stripe_metered_subscription_item_id, :string
      add :monthly_credit_cents, :numeric, precision: 10, scale: 2, default: 0
      add :free_tier_analyses_used, :integer, default: 0
      add :free_tier_analyses_limit, :integer, default: 200
    end
  end
end
