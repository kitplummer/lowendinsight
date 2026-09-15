defmodule Lei.RecoveryCode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "recovery_codes" do
    field(:code_hash, :string)
    field(:used, :boolean, default: false)
    belongs_to(:org, Lei.Org)

    timestamps()
  end

  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:org_id, :code_hash, :used])
    |> validate_required([:org_id, :code_hash])
    |> unique_constraint(:code_hash)
    |> foreign_key_constraint(:org_id)
  end
end
