defmodule LowendinsightGet.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key_hash, :string, null: false
      add :key_prefix, :string, null: false
      add :scopes, {:array, :string}, default: []
      add :active, :boolean, default: true
      add :last_used_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:org_id])
    create index(:api_keys, [:key_prefix])
  end
end
