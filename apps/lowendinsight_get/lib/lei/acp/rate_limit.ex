defmodule Lei.Acp.RateLimit do
  @moduledoc """
  Per-IP rate limiting for the ACP endpoints.

  ACP is deliberately unauthenticated: ADR-001 has agents self-provisioning
  without a pre-shared secret, the same way `/signup` is public. That makes
  authentication the wrong lever for abuse control -- a shared bearer token
  would close the on-ramp the model depends on.

  Rate limiting is the right lever. Without it, an unauthenticated caller can
  create checkout sessions and free orgs without bound: database rows, API
  keys, and cost, from a single client.

  Two buckets, because the endpoints are not equally expensive:

    * `acp`          -- session create/update/cancel, which write one row
    * `acp_complete` -- completion, which creates an **org and an API key**

  Runs before `Plug.Parsers` so an abusive request is rejected without its body
  being read.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    bucket = bucket_for(conn)
    ip = client_ip(conn)

    case Lei.RateLimiter.check("acp:#{bucket}:#{ip}", bucket) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        retry_after = max(div(retry_after_ms, 1000), 1)
        Logger.warning("ACP rate limit: bucket=#{bucket} ip=#{ip} retry_after=#{retry_after}s")

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Poison.encode!(%{error: "rate limited", retry_after_seconds: retry_after})
        )
        |> halt()
    end
  end

  # Completion creates an org and an API key, so it gets a much tighter budget
  # than session bookkeeping.
  defp bucket_for(conn) do
    if List.last(conn.path_info) == "complete", do: "acp_complete", else: "acp"
  end

  # Fly sets fly-client-ip on its proxy, so it cannot be spoofed by the caller.
  # x-forwarded-for can be, so it is only a fallback for non-Fly deployments,
  # and remote_ip is the last resort.
  defp client_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] when is_binary(ip) and ip != "" ->
        ip

      _ ->
        case get_req_header(conn, "x-forwarded-for") do
          [value | _] when is_binary(value) and value != "" ->
            value |> String.split(",") |> List.first() |> String.trim()

          _ ->
            conn.remote_ip |> :inet.ntoa() |> to_string()
        end
    end
  end
end
