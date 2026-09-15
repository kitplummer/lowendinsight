defmodule LeiService.Health do
  @moduledoc """
  Dependency health checks owned by the web app.

  Registered with `Lei.Health` through
  `config :lei_service, :optional_health_checks` so that the `:lei_service`
  library -- which is published to Hex and has no Redis dependency -- does not
  need to know about Redix.
  """

  @ping_timeout_ms 2_000

  @doc """
  Returns `"ok"` when Redis answers PING, `"error"` otherwise.

  Reported as an *optional* dependency: a Redis outage degrades the service,
  because every analysis becomes a cache miss, but does not stop it serving.
  """
  def check_redis do
    case Redix.command(conn(), ["PING"], timeout: @ping_timeout_ms) do
      {:ok, "PONG"} -> "ok"
      _ -> "error"
    end
  rescue
    _ -> "error"
  catch
    _, _ -> "error"
  end

  defp conn, do: Application.get_env(:lei_service, :redix_name, :redix)
end
