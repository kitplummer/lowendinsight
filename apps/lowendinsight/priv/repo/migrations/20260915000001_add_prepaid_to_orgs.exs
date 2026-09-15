defmodule Lei.Repo.Migrations.AddPrepaidToOrgs do
  use Ecto.Migration

  # A prepaid org is admitted on its credit balance and has no monthly
  # allowance. Until now that was inferred from having a wallet address, which
  # left every other prepaid path -- ACP card purchases -- to fall back to the
  # free tier's quota, or to be created as "pro" and never billed (ADR-002).
  def up do
    alter table(:orgs) do
      add :prepaid, :boolean, null: false, default: false
    end

    execute("UPDATE orgs SET prepaid = true WHERE wallet_address IS NOT NULL")
  end

  def down do
    alter table(:orgs) do
      remove :prepaid
    end
  end
end
