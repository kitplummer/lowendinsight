defmodule Lei.Org do
  use Ecto.Schema
  import Ecto.Changeset

  schema "orgs" do
    field :name, :string
    field :slug, :string
    field :tier, :string, default: "free"
    has_many :api_keys, Lei.ApiKey
    timestamps()
  end

  @valid_tiers ~w(free pro)

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :tier])
    |> validate_required([:name])
    |> validate_inclusion(:tier, @valid_tiers)
    |> generate_slug()
    |> unique_constraint(:slug)
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
