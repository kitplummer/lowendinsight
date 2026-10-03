defmodule Lei.Plugs.Adoption do
  @moduledoc """
  Counts which client asked for an analysis (`Lei.Adoption`).

  Only the analysis paths. Counting every request would fold in `/metrics`
  scrapes every fifteen minutes, `/readyz`, the favicon and the landing page —
  which is traffic, not adoption, and would bury the handful of calls the
  question is actually about.

  Runs after authentication, so a request that never got past the door is not
  counted as use. It records before dispatch rather than after: a call that
  arrives and fails is still a client that tried, and that is the more
  interesting number early on.
  """

  @behaviour Plug

  # Prefix match, so /v1/analyze/sbom, /v1/analyze/batch and /v1/analyze/:uuid
  # are all covered. /url= is the Try It form, which is a person rather than an
  # agent, and is counted because the comparison is the point.
  @counted ["/v1/analyze", "/url="]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if counted?(conn.request_path) do
      conn
      |> Plug.Conn.get_req_header("user-agent")
      |> List.first()
      |> Lei.Adoption.record()
    end

    conn
  end

  defp counted?(path), do: Enum.any?(@counted, &String.starts_with?(path, &1))
end
