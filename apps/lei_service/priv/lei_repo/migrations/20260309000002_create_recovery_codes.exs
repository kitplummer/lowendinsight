defmodule Lei.Repo.Migrations.CreateRecoveryCodes do
  use Ecto.Migration

  def change do
    create table(:recovery_codes) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:recovery_codes, [:code_hash])
    create index(:recovery_codes, [:org_id])
  end
end
