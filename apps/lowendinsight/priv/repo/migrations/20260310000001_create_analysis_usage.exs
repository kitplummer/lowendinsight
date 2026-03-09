defmodule Lei.Repo.Migrations.CreateAnalysisUsage do
  use Ecto.Migration

  def change do
    create table(:analysis_usage) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :period_start, :date, null: false
      add :cache_hits, :integer, default: 0
      add :cache_misses, :integer, default: 0
      add :total_cost_cents, :numeric, precision: 10, scale: 2, default: 0

      timestamps()
    end

    create unique_index(:analysis_usage, [:org_id, :period_start])
  end
end
