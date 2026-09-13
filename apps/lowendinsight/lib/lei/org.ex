defmodule Lei.Org do
  use Ecto.Schema
  import Ecto.Changeset

  schema "orgs" do
    field(:name, :string)
    field(:slug, :string)
    field(:tier, :string, default: "free")
    field(:status, :string, default: "pending")
    field(:stripe_customer_id, :string)
    field(:stripe_subscription_id, :string)
    field(:stripe_metered_subscription_item_id, :string)
    field(:monthly_credit_cents, :decimal, default: Decimal.new(0))
    field(:free_tier_analyses_used, :integer, default: 0)
    field(:free_tier_analyses_limit, :integer, default: 200)
    field(:wallet_address, :string)
    has_many(:api_keys, Lei.ApiKey)
    timestamps()
  end

  @valid_tiers ~w(free pro)
  @valid_statuses ~w(pending active suspended)

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :tier, :status])
    |> validate_required([:name])
    |> validate_inclusion(:tier, @valid_tiers)
    |> validate_inclusion(:status, @valid_statuses)
    |> generate_slug()
    |> unique_constraint(:slug)
  end

  def activate_changeset(org) do
    change(org, status: "active")
  end

  def stripe_changeset(org, attrs) do
    org
    |> cast(attrs, [
      :stripe_customer_id,
      :stripe_subscription_id,
      :stripe_metered_subscription_item_id,
      :status
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc """
  Changeset for an org identified by a wallet rather than by a person.

  The address is normalised to lowercase: EVM addresses are hex and
  case-insensitive, and checksummed forms differ only in case. Storing them as
  presented would let the same wallet hold two orgs, which is the thing the
  unique index exists to prevent.
  """
  def wallet_changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :tier, :status, :wallet_address])
    |> update_change(:wallet_address, &normalise_wallet/1)
    |> validate_required([:wallet_address])
    |> validate_format(:wallet_address, ~r/^0x[0-9a-f]{40}$/,
      message: "must be a 0x-prefixed 40-character hex address"
    )
    |> validate_inclusion(:tier, @valid_tiers)
    |> validate_inclusion(:status, @valid_statuses)
    |> put_wallet_slug()
    |> unique_constraint(:slug)
    |> unique_constraint(:wallet_address)
  end

  # Wallet orgs get a slug in a namespace ordinary signup cannot produce.
  #
  # generate_slug/1 maps a name into [a-z0-9-], so deriving a wallet org's slug
  # from its name would let anyone reserve "wallet-0x<someone else's address>"
  # through the normal signup form and block that wallet from ever being
  # provisioned. Not takeover, but a cheap denial of service against a specific
  # address. A dot cannot survive slugify, so this namespace is unreachable
  # from there.
  defp put_wallet_slug(changeset) do
    case get_field(changeset, :wallet_address) do
      address when is_binary(address) and address != "" ->
        put_change(changeset, :slug, "w." <> address)

      _ ->
        changeset
    end
  end

  def normalise_wallet(nil), do: nil
  def normalise_wallet(address) when is_binary(address), do: String.downcase(String.trim(address))
  def normalise_wallet(other), do: other

  def billing_changeset(org, attrs) do
    org
    |> cast(attrs, [
      :monthly_credit_cents,
      :free_tier_analyses_used,
      :free_tier_analyses_limit,
      :stripe_metered_subscription_item_id
    ])
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
