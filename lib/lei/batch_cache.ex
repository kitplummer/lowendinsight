# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchCache do
  @moduledoc """
  ETS-backed in-memory cache for batch analysis results.

  Stores results keyed by {ecosystem, package, version} tuples for fast
  cache lookups during batch SBOM analysis. Separate from the main Lei.Cache
  which stores full analysis reports keyed by repo URL with DETS persistence.
  """

  use GenServer

  @table :lei_batch_cache
  @default_ttl_seconds 3600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec get(String.t(), String.t(), String.t()) :: {:ok, map()} | :miss
  def get(ecosystem, package, version) do
    key = {ecosystem, package, version}

    case :ets.lookup(@table, key) do
      [{^key, result, inserted_at}] ->
        ttl = Application.get_env(:lowendinsight, :batch_cache_ttl_seconds, @default_ttl_seconds)

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

  @spec put(String.t(), String.t(), String.t(), map()) :: :ok
  def put(ecosystem, package, version, result) do
    key = {ecosystem, package, version}
    :ets.insert(@table, {key, result, System.monotonic_time(:second)})
    :ok
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end
end
