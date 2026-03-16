# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.RequestLogger do
  @moduledoc """
  ETS-based ring buffer that keeps the last N API requests in memory.
  Used by the admin dashboard for usage monitoring.
  """

  use GenServer
  require Logger

  @max_entries 1000
  @table :lei_request_log

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [:ordered_set, :public, :named_table])
    {:ok, %{counter: 0}}
  end

  @doc """
  Log an API request. All parameters after endpoint are optional.
  """
  def log_request(endpoint, org_id \\ nil, key_id \\ nil, repo_urls \\ [], cache_status \\ nil) do
    GenServer.cast(__MODULE__, {:log, endpoint, org_id, key_id, repo_urls, cache_status})
  end

  @doc """
  Return the last `count` requests, most recent first.
  """
  def get_recent(count \\ 100) do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {id, _} -> id end, :desc)
    |> Enum.take(count)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  @doc """
  Return all stored requests (up to @max_entries), most recent first.
  """
  def get_all do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {id, _} -> id end, :desc)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  def handle_cast({:log, endpoint, org_id, key_id, repo_urls, cache_status}, %{counter: counter} = state) do
    new_counter = counter + 1

    entry = %{
      id: new_counter,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      endpoint: endpoint,
      org_id: org_id,
      key_id: key_id,
      repo_urls: repo_urls,
      cache_status: cache_status
    }

    :ets.insert(@table, {new_counter, entry})

    # Evict oldest entry when ring buffer is full
    if new_counter > @max_entries do
      :ets.delete(@table, new_counter - @max_entries)
    end

    {:noreply, %{state | counter: new_counter}}
  end
end
