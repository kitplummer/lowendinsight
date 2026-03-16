defmodule Lei.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_keys" do
    field(:name, :string)
    field(:key_hash, :string)
    field(:key_prefix, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:active, :boolean, default: true)
    field(:last_used_at, :utc_datetime_usec)
    belongs_to(:org, Lei.Org)
    timestamps()
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_hash, :key_prefix, :scopes, :active, :org_id])
    |> validate_required([:name, :key_hash, :key_prefix, :org_id])
    |> foreign_key_constraint(:org_id)
    |> unique_constraint(:key_hash)
  end
end
