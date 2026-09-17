defmodule Lei.Repo.Migrations.CreatePaymentOutcomeBuckets do
  use Ecto.Migration

  # How the payment path is doing, by rail: challenges issued, credentials
  # presented, settled, refused and why (#139). One row per hour, rail, outcome
  # and reason, incremented in place, so the table grows with time and not with
  # traffic -- a burst of forged credentials adds to a count rather than rows.
  def change do
    create table(:payment_outcome_buckets) do
      add(:hour, :utc_datetime, null: false)
      add(:rail, :string, null: false)
      add(:outcome, :string, null: false)
      # "" rather than NULL: a unique index treats NULLs as distinct, so a
      # reasonless outcome would get a new row on every increment.
      add(:reason, :string, null: false, default: "")
      add(:count, :bigint, null: false, default: 0)
    end

    create(unique_index(:payment_outcome_buckets, [:hour, :rail, :outcome, :reason]))
  end
end
