defmodule Lei.Repo.Migrations.HoldRefusedPaymentCredentials do
  use Ecto.Migration

  # A stablecoin credential refused because its rail was switched off answers a
  # transfer the agent already made on chain. It is kept here -- and its
  # challenge kept from the purge -- so the payment can be credited or refunded
  # once the incident is over (#139).
  def change do
    alter table(:payment_challenges) do
      add(:held_at, :utc_datetime_usec)
      add(:held_credential, :text)
    end

    create(index(:payment_challenges, [:held_at]))
  end
end
