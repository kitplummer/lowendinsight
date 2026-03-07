defmodule LowendinsightGet.Repo.Migrations.CreateOrgs do
  use Ecto.Migration

  def change do
    create table(:orgs) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :tier, :string, null: false, default: "free"
      timestamps()
    end

    create unique_index(:orgs, [:slug])
  end
end
