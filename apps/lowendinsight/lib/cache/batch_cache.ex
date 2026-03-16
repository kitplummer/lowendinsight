defmodule Lei.BatchCache do
  @moduledoc """
  ETS-backed cache for batch dependency analysis results.

  Stores analysis results keyed by {ecosystem, package, version} tuples
  for fast parallel lookups during batch SBOM analysis. Designed for
  sub-millisecond reads to meet the <500ms target for 50 dependencies.
  """
  use GenServer

  @table :lei_batch_cache
  @default_ttl_seconds 24 * 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a cached analysis result by ecosystem, package, and version.
  Returns {:ok, entry} or {:error, :not_found | :expired}.
  """
  def get(ecosystem, package, version) do
    key = cache_key(ecosystem, package, version)

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        now = System.system_time(:second)

        if entry.expires_at > now do
          {:ok, entry}
        else
          :ets.delete(@table, key)
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Store an analysis result in the cache.
  """
  def put(ecosystem, package, version, result, opts \\ []) do
    key = cache_key(ecosystem, package, version)
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = System.system_time(:second)

    entry = %{
      result: result,
      cached_at: now,
      expires_at: now + ttl,
      ecosystem: ecosystem,
      package: package,
      version: version
    }

    :ets.insert(@table, {key, entry})
    :ok
  end

  @doc """
  Perform parallel cache lookups for a list of dependencies.
  Returns a map of %{key => {:ok, entry} | {:error, reason}}.
  """
  def multi_get(dependencies) do
    dependencies
    |> Task.async_stream(
      fn dep ->
        result = get(dep["ecosystem"], dep["package"], dep["version"])
        {cache_key(dep["ecosystem"], dep["package"], dep["version"]), result}
      end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: 5_000
    )
    |> Enum.reduce(%{}, fn {:ok, {key, result}}, acc ->
      Map.put(acc, key, result)
    end)
  end

  @doc """
  Returns cache statistics.
  """
  def stats do
    now = System.system_time(:second)

    all =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, entry} -> entry.expires_at > now end)

    ecosystems =
      all
      |> Enum.group_by(fn {_key, entry} -> entry.ecosystem end)
      |> Enum.map(fn {eco, items} -> {eco, length(items)} end)
      |> Map.new()

    %{
      count: length(all),
      ecosystems: ecosystems
    }
  end

  @doc """
  Clear all entries from the batch cache.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  defp cache_key(ecosystem, package, version) do
    "#{ecosystem}:#{package}:#{version}"
  end
end
