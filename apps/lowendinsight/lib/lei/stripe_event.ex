defmodule Lei.StripeEvent do
  @moduledoc "A Stripe webhook event that has been acted on. See Lei.StripeWebhookHandler.process/1."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "stripe_events" do
    field(:type, :string)
    timestamps(updated_at: false)
  end
end
