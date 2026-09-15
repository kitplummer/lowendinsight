defmodule Lei.AcpCheckoutSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "acp_checkout_sessions" do
    field(:sku, :string)
    field(:status, :string, default: "open")
    field(:customer_name, :string)
    field(:amount_cents, :integer)
    field(:currency, :string, default: "usd")
    field(:stripe_payment_intent_id, :string)
    field(:metadata, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    belongs_to(:org, Lei.Org)

    timestamps()
  end

  @valid_statuses ~w(open completed cancelled expired)

  # Agents buy credits (ADR-002). There is no free SKU -- an org costs nothing
  # to create here, so any allowance per org is an allowance per attacker --
  # and no Pro SKU: a one-off charge cannot carry a subscription, and Pro
  # without one was unlimited and never billed.
  @skus %{
    "lei-credits-29000" => 2900
  }

  # One credit is $0.001, so a cent buys ten.
  @credits_per_cent 10

  def valid_skus, do: Map.keys(@skus)
  def amount_for_sku(sku), do: Map.get(@skus, sku)
  def credits_for_amount(amount_cents), do: amount_cents * @credits_per_cent

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :id,
      :sku,
      :status,
      :customer_name,
      :amount_cents,
      :currency,
      :stripe_payment_intent_id,
      :metadata,
      :expires_at,
      :org_id
    ])
    |> validate_required([:id, :sku, :amount_cents, :expires_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:sku, Map.keys(@skus))
  end

  def update_changeset(session, attrs) do
    session
    |> cast(attrs, [:customer_name, :status, :stripe_payment_intent_id, :metadata, :org_id])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
