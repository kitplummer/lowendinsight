defmodule Lei.Health do
  @moduledoc """
  Health check functions for liveness and readiness probes.
  """

  def liveness do
    %{status: "ok"}
  end

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
