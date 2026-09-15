defmodule Lei.Repo.Migrations.CreateStripeEvents do
  use Ecto.Migration

  # One row per Stripe event acted on. Written in the same transaction as the
  # event's effects, so an event is either applied and recorded, or neither --
  # and a redelivery of a recorded event is skipped. Stripe delivers at least
  # once, and a captured delivery could otherwise be replayed.
  def change do
    create table(:stripe_events, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:type, :string, null: false)

      timestamps(updated_at: false)
    end
  end
end
