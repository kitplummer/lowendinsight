# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.Analysis do
  require Logger

  def analyze(url, source, options) do
    if Process.whereis(:counter) do
      LowendinsightGet.CounterAgent.add(self(), url)
    end

    case LowendinsightGet.Datastore.get_from_cache(
           url,
           Application.get_env(:lowendinsight_get, :cache_ttl)
         ) do
      {:ok, repo_report, :hit} ->
        Logger.info("#{url} is cached, yay!")
        repo_data = Poison.decode!(repo_report, as: %RepoReport{data: %Data{results: %Results{}}})
        {:ok, repo_data, :hit}

      {:error, msg, _cache_status} ->
        Logger.info("No cache: #{msg}")
        {:ok, rep} = AnalyzerModule.analyze(url, source, options)
        LowendinsightGet.Datastore.write_to_cache(url, rep)
        {:ok, rep, :miss}
    end
  end

  def process(uuid, urls, start_time) do
    Logger.info("processing #{uuid} -> #{inspect(urls)}")
    LowendinsightGet.CounterAgent.new_counter(Enum.count(urls))

    results =
      urls
      |> Task.async_stream(__MODULE__, :analyze, ["lei-get", %{types: false}],
        timeout: :infinity,
        max_concurrency: 1
      )
      |> Enum.map(fn {:ok, {_status, repo, cache_status}} -> {repo, cache_status} end)

    repos = Enum.map(results, fn {repo, _status} -> repo end)
    cache_statuses = Enum.map(results, fn {_repo, status} -> Atom.to_string(status) end)

    LowendinsightGet.CounterAgent.update()

    cache_hits = Enum.count(cache_statuses, &(&1 == "hit"))
    cache_misses = Enum.count(cache_statuses, &(&1 == "miss"))

    report = %{
      state: "complete",
      report: %{uuid: UUID.uuid1(), repos: repos},
      metadata: %{
        repo_count: length(repos),
        cache_status: %{
          hits: cache_hits,
          misses: cache_misses,
          per_repo: cache_statuses
        }
      }
    }

    report = AnalyzerModule.determine_risk_counts(report)

    end_time = DateTime.utc_now()
    duration = DateTime.diff(end_time, start_time)

    times = %{
      start_time: DateTime.to_iso8601(start_time),
      end_time: DateTime.to_iso8601(end_time),
      duration: duration
    }

    metadata = Map.put_new(report[:metadata], :times, times)
    report = report |> Map.put(:metadata, metadata)

    report = report |> Map.put(:uuid, uuid)
    ## We're finished with all the analysis work, write the report to datastore
    LowendinsightGet.Datastore.write_job(uuid, report)
    {:ok, report}
  end

  # Backward-compatible 3-arity wrapper — defaults to async mode (original behavior)
  def process_urls(urls, uuid, start_time) do
    process_urls(urls, uuid, start_time, %{cache_mode: "async"})
  end

  # 4-arity with opts map supporting cache_mode and cache_timeout
  def process_urls(urls, uuid, start_time, opts) do
    if :ok == Helpers.validate_urls(urls) do
      cache_mode = Map.get(opts, :cache_mode, "async")

      case cache_mode do
        "stale" ->
          process_urls_stale(urls, uuid, start_time)

        "blocking" ->
          timeout =
            Map.get(
              opts,
              :cache_timeout,
              Application.get_env(:lowendinsight_get, :default_cache_timeout, 30_000)
            )

          process_urls_blocking(urls, uuid, start_time, timeout)

        _ ->
          # "async" — original behavior
          process_urls_async(urls, uuid, start_time)
      end
    else
      {:error, "invalid URLs list"}
    end
  end

  # Original process_urls logic extracted into async path
  defp process_urls_async(urls, uuid, start_time) do
    Logger.debug("started #{uuid} at #{start_time}")

    empty = AnalyzerModule.create_empty_report(uuid, urls, start_time)

    cache_results =
      urls
      |> Enum.map(fn url ->
        case LowendinsightGet.Datastore.get_from_cache(url, 28) do
          {:ok, report, :hit} ->
            {Poison.decode!(report), :hit}

          {:error, msg, status} ->
            Logger.debug(msg)
            {%{data: %{repo: url}}, status}
        end
      end)

    repos = Enum.map(cache_results, fn {repo, _status} -> repo end)
    cache_statuses = Enum.map(cache_results, fn {_repo, status} -> Atom.to_string(status) end)

    uncached_urls =
      urls
      |> Enum.filter(fn url -> !LowendinsightGet.Datastore.in_cache?(url) end)

    cache_hits = Enum.count(cache_statuses, &(&1 == "hit"))
    cache_misses = length(cache_statuses) - cache_hits

    if length(uncached_urls) == 0 do
      metadata = empty[:metadata]
      times = metadata[:times]
      end_time = DateTime.utc_now()
      times = Map.replace!(times, :end_time, end_time)
      metadata = Map.replace!(metadata, :times, times)

      metadata =
        Map.put(metadata, :cache_status, %{
          hits: cache_hits,
          misses: cache_misses,
          per_repo: cache_statuses
        })

      updated_report = Map.replace!(empty, :metadata, metadata)
      updated_report = Map.replace!(updated_report, :state, "complete")
      final_report = Map.replace!(updated_report, :report, %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, final_report)
      {:ok, Poison.encode!(final_report)}
    else
      partial_report = Map.replace!(empty, :report, %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, partial_report)

      case LowendinsightGet.AnalysisSupervisor.perform_analysis(uuid, uncached_urls, start_time) do
        {:ok, task} ->
          Logger.info(task)
          {:ok, Poison.encode!(partial_report)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # Blocking path: queue analysis then poll until complete or timeout
  defp process_urls_blocking(urls, uuid, start_time, timeout) do
    Logger.debug("blocking mode: started #{uuid} at #{start_time}")

    empty = AnalyzerModule.create_empty_report(uuid, urls, start_time)

    cache_results =
      urls
      |> Enum.map(fn url ->
        case LowendinsightGet.Datastore.get_from_cache(url, 28) do
          {:ok, report, :hit} ->
            {Poison.decode!(report), :hit}

          {:error, msg, status} ->
            Logger.debug(msg)
            {%{data: %{repo: url}}, status}
        end
      end)

    repos = Enum.map(cache_results, fn {repo, _status} -> repo end)
    cache_statuses = Enum.map(cache_results, fn {_repo, status} -> Atom.to_string(status) end)

    uncached_urls =
      urls
      |> Enum.filter(fn url -> !LowendinsightGet.Datastore.in_cache?(url) end)

    cache_hits = Enum.count(cache_statuses, &(&1 == "hit"))
    cache_misses = length(cache_statuses) - cache_hits

    if length(uncached_urls) == 0 do
      metadata = empty[:metadata]
      times = metadata[:times]
      end_time = DateTime.utc_now()
      times = Map.replace!(times, :end_time, end_time)
      metadata = Map.replace!(metadata, :times, times)

      metadata =
        Map.put(metadata, :cache_status, %{
          hits: cache_hits,
          misses: cache_misses,
          per_repo: cache_statuses
        })

      updated_report = Map.replace!(empty, :metadata, metadata)
      updated_report = Map.replace!(updated_report, :state, "complete")
      final_report = Map.replace!(updated_report, :report, %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, final_report)
      {:ok, Poison.encode!(final_report)}
    else
      partial_report = Map.replace!(empty, :report, %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, partial_report)

      case LowendinsightGet.AnalysisSupervisor.perform_analysis(uuid, uncached_urls, start_time) do
        {:ok, _task} ->
          case poll_job(uuid, timeout) do
            {:ok, report_json} ->
              {:ok, report_json}

            {:timeout, uuid} ->
              {:timeout, uuid}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # Poll Redis job every 500ms until complete or deadline
  defp poll_job(uuid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_job_loop(uuid, deadline)
  end

  defp poll_job_loop(uuid, deadline) do
    case LowendinsightGet.Datastore.get_job(uuid) do
      {:ok, job_json} ->
        job = Poison.decode!(job_json)

        case job["state"] do
          "complete" ->
            {:ok, job_json}

          _ ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:timeout, uuid}
            else
              :timer.sleep(500)
              poll_job_loop(uuid, deadline)
            end
        end

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, uuid}
        else
          :timer.sleep(500)
          poll_job_loop(uuid, deadline)
        end
    end
  end

  # Stale path: return stale cached data if available, trigger background refresh
  defp process_urls_stale(urls, uuid, start_time) do
    Logger.debug("stale mode: started #{uuid} at #{start_time}")

    # Try to get stale cache for each URL
    cache_results =
      urls
      |> Enum.map(fn url ->
        case LowendinsightGet.Datastore.get_from_cache_any_age(url) do
          {:ok, data, :stale} -> {:hit, url, Poison.decode!(data)}
          {:error, _, :miss} -> {:miss, url, nil}
        end
      end)

    all_cached = Enum.all?(cache_results, fn {status, _, _} -> status == :hit end)

    if all_cached do
      repos = Enum.map(cache_results, fn {:hit, _url, data} -> data end)

      end_time = DateTime.utc_now()
      duration = DateTime.diff(end_time, start_time)

      report = %{
        state: "complete",
        stale: true,
        refresh_job_id: uuid,
        uuid: uuid,
        report: %{uuid: UUID.uuid1(), repos: repos},
        metadata: %{
          repo_count: length(repos),
          times: %{
            start_time: DateTime.to_iso8601(start_time),
            end_time: DateTime.to_iso8601(end_time),
            duration: duration
          }
        }
      }

      LowendinsightGet.Datastore.write_job(uuid, report)

      # Trigger background refresh
      Task.start(fn ->
        LowendinsightGet.AnalysisSupervisor.perform_analysis(uuid, urls, start_time)
      end)

      {:ok, Poison.encode!(report)}
    else
      # Some URLs have no cache at all, fall back to async behavior
      process_urls_async(urls, uuid, start_time)
    end
  end

  def refresh_job(job) do
    uuid = job["uuid"]
    repos = job["report"]["repos"]

    urls =
      repos
      |> Enum.reduce([], fn object, acc ->
        repo = object["data"]["repo"]

        if !Map.has_key?(object["data"], "results") do
          [repo | acc]
        else
          acc
        end
      end)

    ## Populate with results from cache (within 30 days)
    cache_results =
      urls
      |> Enum.map(fn url ->
        case LowendinsightGet.Datastore.get_from_cache(url, 28) do
          {:ok, report, :hit} ->
            {Poison.decode!(report), :hit}

          {:error, msg, status} ->
            Logger.debug(msg)
            {%{data: %{repo: url}}, status}
        end
      end)

    repos = Enum.map(cache_results, fn {repo, _status} -> repo end)
    cache_statuses = Enum.map(cache_results, fn {_repo, status} -> Atom.to_string(status) end)

    # Update URL list
    urls =
      urls
      |> Enum.filter(fn url ->
        !LowendinsightGet.Datastore.in_cache?(url)
      end)
      |> Enum.map(fn url -> url end)

    cache_hits = Enum.count(cache_statuses, &(&1 == "hit"))
    cache_misses = length(cache_statuses) - cache_hits

    if length(urls) == 0 do
      metadata = job["metadata"]
      times = metadata["times"]
      end_time = DateTime.utc_now()
      times = Map.replace!(times, "end_time", end_time)
      metadata = Map.replace!(metadata, "times", times)

      metadata =
        Map.put(metadata, "cache_status", %{
          "hits" => cache_hits,
          "misses" => cache_misses,
          "per_repo" => cache_statuses
        })

      updated_report = Map.replace!(job, "metadata", metadata)
      updated_report = Map.replace!(updated_report, "state", "complete")
      final_report = Map.replace!(updated_report, "report", %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, final_report)
      final_report
    else
      partial_report = Map.replace!(job, "report", %{:repos => repos})
      LowendinsightGet.Datastore.write_job(uuid, partial_report)

      case LowendinsightGet.AnalysisSupervisor.perform_analysis(
             uuid,
             urls,
             job["metadata"]["times"]["start_time"]
           ) do
        {:ok, task} ->
          Logger.info(task)
          partial_report

        {:error, error} ->
          {:error, error}
      end
    end
  end
end
