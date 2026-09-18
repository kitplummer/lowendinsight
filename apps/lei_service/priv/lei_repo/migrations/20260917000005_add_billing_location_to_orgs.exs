defmodule Lei.Repo.Migrations.AddBillingLocationToOrgs do
  use Ecto.Migration

  # Where the buyer is. Stripe Tax calculates from an address, and an agent
  # payment carries none: no shipping address, no billing details, and Stripe
  # advises against inferring US location from IP (kitplummer/lowendinsight#223,
  # ADR-002 "The location problem"). The ledger's `jurisdiction` column has
  # existed for this since the ledger was built and nothing has ever filled it.
  #
  # Nullable: every org predates this, and whether a location is required
  # before a purchase is configuration, not a database constraint.
  def change do
    alter table(:orgs) do
      add :billing_country, :string
      add :billing_postal_code, :string
    end
  end
end
