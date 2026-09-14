defmodule Lei.Repo.Migrations.AllowAnonymousPaymentChallenges do
  use Ecto.Migration

  # An agent that has never been here is issued a challenge before any org
  # exists for it: the org comes from the payment, not the request (#147). The
  # foreign key stays -- a present org_id must still name a real org -- and
  # settlement fills it in, so an answered challenge always records who paid.
  def up do
    execute("ALTER TABLE payment_challenges ALTER COLUMN org_id DROP NOT NULL")
  end

  def down do
    execute("ALTER TABLE payment_challenges ALTER COLUMN org_id SET NOT NULL")
  end
end
