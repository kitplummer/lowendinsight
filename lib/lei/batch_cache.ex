# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchCache do
  @moduledoc """
  ETS-backed cache for batch dependency analysis results.

  Stores analysis results keyed by `{ecosystem, package, version}` tuples
  for fast parallel lookups during batch SBOM analysis.
  """

  @table :lei_batch_cache
  @default_ttl_seconds 30 * 24 * 3600

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Stores an analysis result for a dependency.
  """
  def put(ecosystem, package, version, result, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = System.system_time(:second)
    key = cache_key(ecosystem, package, version)

    entry = %{
      result: result,
      cached_at: now,
      expires_at: now + ttl,
      ecosystem: ecosystem
    }

    :ets.insert(@table, {key, entry})
    :ok
  end

  @doc """
  Retrieves a cached result for a dependency. Returns `{:ok, entry}` or `{:error, reason}`.
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
  Performs parallel cache lookups for a list of dependencies.
  Returns `{cached_results, cache_misses}`.
  """
  def lookup_batch(deps) do
    deps
    |> Task.async_stream(
      fn dep ->
        case get(dep["ecosystem"], dep["package"], dep["version"]) do
          {:ok, entry} -> {:hit, dep, entry}
          {:error, _} -> {:miss, dep}
        end
      end,
      max_concurrency: System.schedulers_online() * 2,
      timeout: 5_000
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:hit, dep, entry}}, {hits, misses} ->
        {[{dep, entry} | hits], misses}

      {:ok, {:miss, dep}}, {hits, misses} ->
        {hits, [dep | misses]}

      {:exit, _reason}, {hits, misses} ->
        {hits, misses}
    end)
  end

  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp cache_key(ecosystem, package, version) do
    {String.downcase(to_string(ecosystem)), String.downcase(to_string(package)),
     to_string(version)}
  end
end
