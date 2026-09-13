defmodule Lei.Repo.Migrations.CreatePaymentChallenges do
  use Ecto.Migration

  def change do
    create table(:payment_challenges) do
      # The challenge id from the WWW-Authenticate header. The credential
      # echoes it, and that echo is only worth checking against a challenge we
      # actually issued -- comparing it against its own copy would be circular.
      add(:challenge_id, :string, null: false)
      add(:org_id, references(:orgs, on_delete: :restrict), null: false)
      add(:rail, :string, null: false)
      add(:credits, :bigint, null: false)
      add(:amount_cents, :integer, null: false)
      add(:header, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:settled_at, :utc_datetime_usec)

      timestamps(updated_at: false)
    end

    create(unique_index(:payment_challenges, [:challenge_id]))
    create(index(:payment_challenges, [:org_id]))
    # Issued and never answered: an agent that asked the price and walked away.
    # Worth being able to count rather than losing.
    create(index(:payment_challenges, [:settled_at]))

    # Postgres rather than a cache, because the app runs more than one node and
    # a challenge issued by one is answered against another. It also makes an
    # unanswered challenge a row somebody can count instead of something that
    # quietly evaporates.
  end
end
