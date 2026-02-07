defmodule Lei.Cache do
  use GenServer

  @table :lei_analysis_cache
  @default_ttl_seconds 3600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get(ecosystem, package, version) do
    key = cache_key(ecosystem, package, version)

    case :ets.lookup(@table, key) do
      [{^key, result, inserted_at}] ->
        ttl = Application.get_env(:lowendinsight, :cache_ttl_seconds, @default_ttl_seconds)

        if System.monotonic_time(:second) - inserted_at < ttl do
          {:ok, result}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  def put(ecosystem, package, version, result) do
    key = cache_key(ecosystem, package, version)
    :ets.insert(@table, {key, result, System.monotonic_time(:second)})
    :ok
  end

  defp cache_key(ecosystem, package, version) do
    {ecosystem, package, version}
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
