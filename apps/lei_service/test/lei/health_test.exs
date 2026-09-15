defmodule Lei.HealthTest do
  @moduledoc """
  Unit tests for readiness status resolution.

  The distinction that matters: an optional dependency failing must report
  "degraded" (still served) rather than "error" (out of rotation). Getting
  this backwards turns a cache outage into a total outage.
  """
  use ExUnit.Case, async: false

  defmodule OkCheck do
    def run, do: "ok"
  end

  defmodule FailingCheck do
    def run, do: "error"
  end

  defmodule RaisingCheck do
    def run, do: raise("boom")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    previous = Application.get_env(:lowendinsight, :optional_health_checks)

    on_exit(fn ->
      if previous do
        Application.put_env(:lowendinsight, :optional_health_checks, previous)
      else
        Application.delete_env(:lowendinsight, :optional_health_checks)
      end
    end)

    :ok
  end

  defp with_checks(checks) do
    Application.put_env(:lowendinsight, :optional_health_checks, checks)
    Lei.Health.readiness()
  end

  test "liveness is unconditional" do
    assert Lei.Health.liveness() == %{status: "ok"}
  end

  # --- Pre-existing coverage, retained ---

  test "readiness checks database" do
    result = Lei.Health.readiness()
    assert result.status in ["ok", "degraded"]
    assert Map.has_key?(result.checks, :database)
  end

  test "readiness returns ok when database is available" do
    result = Lei.Health.readiness()
    assert result.status == "ok"
    assert result.checks.database == "ok"
  end

  # --- Optional-dependency resolution ---

  test "no optional checks means ok" do
    health = with_checks([])
    assert health.status == "ok"
    assert health.checks == %{database: "ok"}
  end

  test "passing optional check keeps status ok and is reported" do
    health = with_checks(cache: {OkCheck, :run, []})
    assert health.status == "ok"
    assert health.checks[:cache] == "ok"
  end

  test "failing optional check degrades rather than errors" do
    health = with_checks(cache: {FailingCheck, :run, []})
    assert health.status == "degraded"
    assert health.checks[:cache] == "error"
    # Required dependency is still fine, so this instance can still serve.
    assert health.checks[:database] == "ok"
  end

  test "a check that raises is a failing check, not a crashing probe" do
    health = with_checks(cache: {RaisingCheck, :run, []})
    assert health.status == "degraded"
    assert health.checks[:cache] == "error"
  end

  test "a check whose module is not loaded is skipped, not failed" do
    health = with_checks(cache: {ThisModuleDoesNotExist, :run, []})
    assert health.status == "ok"
    refute Map.has_key?(health.checks, :cache)
  end
end
