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
    |> cast(attrs, [:stripe_customer_id, :stripe_subscription_id, :status])
    |> validate_inclusion(:status, @valid_statuses)
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
