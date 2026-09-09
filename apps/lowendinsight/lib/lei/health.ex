defmodule Lei.Health do
  @moduledoc """
  Health check functions for liveness and readiness probes.

  Readiness distinguishes *required* dependencies from *optional* ones:

    * a **required** dependency failing means the instance cannot serve, so
      readiness reports `"error"` and the caller should return 503
    * an **optional** dependency failing means the instance is `"degraded"` --
      still serving, with reduced function -- so readiness stays 200 and the
      failing check is visible in the response body

  Redis is optional by this definition. Analysis still works without the cache;
  it is just slower, and every lookup is a miss. Failing readiness on Redis
  would pull the instance out of rotation and turn a cache outage into a total
  outage.

  Optional checks are registered as `{name, {module, function, args}}` under
  `config :lowendinsight, :optional_health_checks`. A check whose module is not
  loaded is skipped rather than reported as failing, which keeps this library
  free of a Redis dependency and lets the umbrella's web app supply the check.
  """

  def liveness do
    %{status: "ok"}
  end

  @doc """
  Returns `%{status: status, checks: checks}` where status is one of
  `"ok"`, `"degraded"` (an optional dependency is down) or `"error"`
  (a required dependency is down).
  """
  def readiness do
    required = %{database: check_database()}
    optional = run_optional_checks()

    status =
      cond do
        Enum.any?(required, fn {_name, result} -> result != "ok" end) -> "error"
        Enum.any?(optional, fn {_name, result} -> result != "ok" end) -> "degraded"
        true -> "ok"
      end

    %{status: status, checks: Map.merge(required, optional)}
  end

  defp run_optional_checks do
    :lowendinsight
    |> Application.get_env(:optional_health_checks, [])
    |> Enum.flat_map(fn {name, {module, function, args}} ->
      if Code.ensure_loaded?(module) do
        [{name, safe_check(module, function, args)}]
      else
        []
      end
    end)
    |> Map.new()
  end

  # A check that raises or exits is a failing check, never a crashing probe.
  defp safe_check(module, function, args) do
    case apply(module, function, args) do
      result when is_binary(result) -> result
      _ -> "error"
    end
  rescue
    _ -> "error"
  catch
    _, _ -> "error"
  end

  defp check_database do
    case Lei.Repo.query("SELECT 1") do
      {:ok, _} -> "ok"
      {:error, _} -> "error"
    end
  rescue
    _ -> "error"
  end
end
