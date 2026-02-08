# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Registry do
  @moduledoc """
  Tracks pending analysis jobs for batch requests.

  Uses ETS for fast concurrent reads. Jobs are created when a batch request
  encounters cache misses and need async analysis.
  """

  use GenServer

  @table :lei_jobs

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Creates a new job entry and returns its ID.
  """
  def create_job(dep) do
    job_id = "job-#{UUID.uuid4() |> String.split("-") |> hd()}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    :ets.insert(@table, {job_id, %{status: :pending, dep: dep, created_at: now, result: nil}})
    job_id
  end

  @doc """
  Updates a job's status and optionally its result.
  """
  def update_job(job_id, status, result \\ nil) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, entry}] ->
        :ets.insert(@table, {job_id, %{entry | status: status, result: result}})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Retrieves a job by ID.
  """
  def get_job(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end
end
