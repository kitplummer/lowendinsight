defmodule Lei.Repo.Migrations.AddWalletAddressToOrgs do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :wallet_address, :string
    end

    # Unique where present. One wallet, one org -- and the database is what
    # enforces it, not a pre-check SELECT, because two concurrent provisioning
    # requests both pass a pre-check and only one can win an index.
    #
    # Orgs without a wallet are unconstrained: most orgs are email-identified
    # and have no wallet at all.
    create unique_index(:orgs, [:wallet_address], where: "wallet_address IS NOT NULL")
  end
end
