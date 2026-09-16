defmodule LeiService.QueueHealth do
  @moduledoc """
  Reports whether background work is moving.

  Production ran Oban with no plugins, and 79 jobs sat `executing` for days
  (ADR-004, #194). Every check was green: readiness asked about Postgres and
  Redis, the smoke test asked about the API, and neither asks whether the work
  a request promised ever ran.

  Two questions, both answerable in one query:

    * is anything executing far longer than a job should take -- which means
      Lifeline did not rescue it, because it is stuck rather than slow
    * has anything been waiting to start for longer than a backlog should last

  Registered as an optional readiness check, so a failure reads as "degraded"
  (the instance still serves) and the monitor's degraded alert covers it.
  """

  @defaults [stuck_after_minutes: 90, backlog_after_minutes: 15]

  @doc """
  `"ok"`, or a sentence naming what is wrong. Never raises: a check that
  cannot run reports an error rather than crashing the probe.
  """
  def status(opts \\ []) do
    case snapshot(opts) do
      {:error, reason} ->
        "error: #{reason}"

      snapshot ->
        stuck_minutes = config(:stuck_after_minutes)
        backlog_minutes = config(:backlog_after_minutes)

        cond do
          snapshot.stuck > 0 ->
            "#{snapshot.stuck} job(s) executing over #{stuck_minutes}m"

          snapshot.oldest_available_seconds > backlog_minutes * 60 ->
            "oldest queued job waiting #{div(snapshot.oldest_available_seconds, 60)}m"

          true ->
            "ok"
        end
    end
  end

  @doc """
  `%{available:, executing:, retryable:, stuck:, oldest_available_seconds:}`,
  or `{:error, reason}`.

  `available` counts only jobs whose scheduled time has passed: a job
  scheduled for later is waiting on purpose, not a backlog.
  """
  def snapshot(opts \\ []) do
    repo = Keyword.get(opts, :repo, LeiService.Repo)
    stuck_seconds = config(:stuck_after_minutes) * 60

    # Oban stores naive UTC timestamps, so compare against UTC rather than
    # now(), which carries the database's timezone.
    query = """
    SELECT
      count(*) FILTER (WHERE state = 'available' AND scheduled_at <= (now() AT TIME ZONE 'UTC')),
      count(*) FILTER (WHERE state = 'executing'),
      count(*) FILTER (WHERE state = 'retryable'),
      count(*) FILTER (WHERE state = 'executing' AND attempted_at < (now() AT TIME ZONE 'UTC') - ($1 || ' seconds')::interval),
      coalesce(extract(epoch FROM (now() AT TIME ZONE 'UTC') - min(scheduled_at) FILTER (WHERE state = 'available' AND scheduled_at <= (now() AT TIME ZONE 'UTC'))), 0)::bigint
    FROM oban_jobs
    """

    case Ecto.Adapters.SQL.query(repo, query, [to_string(stuck_seconds)]) do
      {:ok, %{rows: [[available, executing, retryable, stuck, oldest]]}} ->
        %{
          available: available,
          executing: executing,
          retryable: retryable,
          stuck: stuck,
          oldest_available_seconds: oldest
        }

      {:error, error} ->
        {:error, inspect(error) |> String.slice(0, 120)}
    end
  rescue
    error -> {:error, inspect(error) |> String.slice(0, 120)}
  catch
    _, reason -> {:error, inspect(reason) |> String.slice(0, 120)}
  end

  @doc "Prometheus gauges for /metrics."
  def metrics(opts \\ []) do
    case snapshot(opts) do
      {:error, _reason} ->
        ["# HELP lei_queue_error The queue could not be read", "lei_queue_error 1"]

      s ->
        [
          "# HELP lei_queue_jobs Oban jobs by state",
          "# TYPE lei_queue_jobs gauge",
          ~s(lei_queue_jobs{state="available"} #{s.available}),
          ~s(lei_queue_jobs{state="executing"} #{s.executing}),
          ~s(lei_queue_jobs{state="retryable"} #{s.retryable}),
          "",
          "# HELP lei_queue_stuck_jobs Jobs executing longer than a job should take",
          "# TYPE lei_queue_stuck_jobs gauge",
          "lei_queue_stuck_jobs #{s.stuck}",
          "",
          "# HELP lei_queue_oldest_available_seconds Age of the oldest job waiting to start",
          "# TYPE lei_queue_oldest_available_seconds gauge",
          "lei_queue_oldest_available_seconds #{s.oldest_available_seconds}"
        ]
    end
  end

  defp config(key) do
    :lei_service
    |> Application.get_env(:queue_health, [])
    |> Keyword.get(key, @defaults[key])
  end
end
