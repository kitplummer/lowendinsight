defmodule Lei.HealthTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  test "liveness returns ok" do
    result = Lei.Health.liveness()
    assert result.status == "ok"
  end

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
end
