defmodule Lei.Repo.Migrations.CreatePaymentSwitches do
  use Ecto.Migration

  # The kill switch for each payment path (#139). Append-only, like the
  # ledger: the current state is the latest row per path, and every change
  # keeps who made it and why. A path with no rows is on.
  def change do
    create table(:payment_switches) do
      add(:path, :string, null: false)
      add(:enabled, :boolean, null: false)
      add(:reason, :text, null: false)
      add(:actor, :string, null: false)

      timestamps(updated_at: false)
    end

    create(index(:payment_switches, [:path, :id]))
  end
end
