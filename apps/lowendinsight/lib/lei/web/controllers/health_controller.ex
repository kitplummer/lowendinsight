defmodule Lei.Web.Controllers.HealthController do
  @moduledoc """
  Handler for the GET /v1/health endpoint.

  Returns JSON with status, app version, and uptime in seconds.
  Accessible without authentication.
  """
  import Plug.Conn

  def get(conn) do
    version =
      :lowendinsight
      |> Application.spec(:vsn)
      |> to_string()

    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_seconds = div(uptime_ms, 1000)

    body =
      Poison.encode!(%{
        status: "ok",
        version: version,
        uptime_seconds: uptime_seconds
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
