defmodule Lei.AnalysisUsage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "analysis_usage" do
    field(:period_start, :date)
    field(:cache_hits, :integer, default: 0)
    field(:cache_misses, :integer, default: 0)
    field(:total_cost_cents, :decimal, default: Decimal.new(0))
    belongs_to(:org, Lei.Org)
    belongs_to(:api_key, Lei.ApiKey)

    timestamps()
  end

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [
      :org_id,
      :api_key_id,
      :period_start,
      :cache_hits,
      :cache_misses,
      :total_cost_cents
    ])
    |> validate_required([:org_id, :period_start])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:api_key_id)
    |> unique_constraint([:org_id, :period_start])
  end
end
