defmodule Lei.Health do
  @moduledoc """
  Health check functions for liveness and readiness probes.
  """

  @doc """
  Liveness check — confirms the BEAM is running.
  Always returns :ok unless the system is truly dead.
  """
  def liveness do
    %{status: "ok"}
  end

  @doc """
  Readiness check — verifies database connectivity.
  Returns :ok or :degraded with per-check details.
  """
  def readiness do
    checks = %{
      database: check_database()
    }

    all_ok = Enum.all?(checks, fn {_k, v} -> v == "ok" end)

    %{
      status: if(all_ok, do: "ok", else: "degraded"),
      checks: checks
    }
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
