# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache do
  @moduledoc """
  ETS-backed cache for LowEndInsight analysis results with DETS persistence.

  Stores analysis reports keyed by repo URL. Each entry includes a timestamp
  and optional TTL for expiration. The cache persists across restarts via DETS.
  """

  @table :lei_cache
  @dets_table :lei_cache_dets
  @default_ttl_seconds 30 * 24 * 3600

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    cache_dir = cache_dir()
    File.mkdir_p!(cache_dir)
    dets_path = Path.join(cache_dir, "lei_cache.dets") |> String.to_charlist()

    case :dets.open_file(@dets_table, file: dets_path, type: :set) do
      {:ok, _} ->
        :dets.to_ets(@dets_table, @table)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def put(key, report, opts \\ []) do
    ecosystem = Keyword.get(opts, :ecosystem, detect_ecosystem(report))
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = DateTime.utc_now() |> DateTime.to_unix()
    expires_at = now + ttl

    entry = {key, %{
      report: report,
      cached_at: now,
      expires_at: expires_at,
      ecosystem: ecosystem
    }}

    :ets.insert(@table, entry)
    sync_to_dets()
    :ok
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        now = DateTime.utc_now() |> DateTime.to_unix()

        if entry.expires_at > now do
          {:ok, entry}
        else
          :ets.delete(@table, key)
          sync_to_dets()
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def all_valid do
    now = DateTime.utc_now() |> DateTime.to_unix()

    :ets.tab2list(@table)
    |> Enum.filter(fn {_key, entry} -> entry.expires_at > now end)
    |> Enum.sort_by(fn {_key, entry} -> entry.cached_at end)
  end

  def count do
    all_valid() |> length()
  end

  def stats do
    entries = all_valid()

    ecosystems =
      entries
      |> Enum.group_by(fn {_key, entry} -> entry.ecosystem end)
      |> Enum.map(fn {eco, items} -> {eco, length(items)} end)
      |> Map.new()

    oldest =
      case entries do
        [] -> nil
        _ ->
          {_key, entry} = Enum.min_by(entries, fn {_key, e} -> e.cached_at end)
          entry.cached_at |> DateTime.from_unix!() |> DateTime.to_iso8601()
      end

    %{
      count: length(entries),
      ecosystems: ecosystems,
      oldest_entry: oldest
    }
  end

  def clear do
    :ets.delete_all_objects(@table)
    sync_to_dets()
    :ok
  end

  def close do
    :dets.close(@dets_table)
  end

  defp sync_to_dets do
    :ets.to_dets(@table, @dets_table)
  end

  defp cache_dir do
    Application.get_env(:lowendinsight, :cache_dir) ||
      Path.join(Application.get_env(:lowendinsight, :base_temp_dir, "/tmp"), "lei_cache")
  end

  defp detect_ecosystem(report) do
    types = get_in(report, [:data, :project_types]) || %{}

    cond do
      is_map(types) && Map.has_key?(types, "mix") -> "hex"
      is_map(types) && Map.has_key?(types, "npm") -> "npm"
      is_map(types) && Map.has_key?(types, "yarn") -> "npm"
      is_map(types) && Map.has_key?(types, "pip") -> "pypi"
      is_map(types) && Map.has_key?(types, "cargo") -> "crates"
      is_list(types) && Enum.any?(types, &match?({:mix, _}, &1)) -> "hex"
      is_list(types) && Enum.any?(types, &match?({:npm, _}, &1)) -> "npm"
      is_list(types) && Enum.any?(types, &match?({:pip, _}, &1)) -> "pypi"
      is_list(types) && Enum.any?(types, &match?({:cargo, _}, &1)) -> "crates"
      true -> "unknown"
    end
  end
end
