defmodule Lei.Payments.RateLimit do
  @moduledoc """
  Per-IP rate limiting for the payment exchange.

  The 402 path is unauthenticated by necessity: an agent that has never been
  here cannot present a key, and requiring one would close the on-ramp the
  whole model depends on. So rate limiting is the lever, the same reasoning as
  `Lei.Acp.RateLimit`.

  Two buckets, because the halves cost very different amounts:

    * `payment_challenge` -- issuing a 402. Cheap, but it writes a row, so an
      unbounded caller can fill a table by repeatedly asking the price.

    * `payment_settle`    -- presenting a credential. Each attempt can reach
      Stripe, so this is the expensive half and the one an attacker would use
      to grind through stolen tokens. Much tighter.

  Runs before the body is parsed, so an abusive request is rejected without
  being read.
  """

  import Plug.Conn

  require Logger

  @doc """
  Checks the bucket for this request, returning the conn halted with a 429 if
  it is exhausted.
  """
  def check(conn, bucket) when bucket in [:payment_challenge, :payment_settle] do
    ip = client_ip(conn)
    name = Atom.to_string(bucket)

    case Lei.RateLimiter.check("payments:#{name}:#{ip}", name) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        retry_after = max(div(retry_after_ms, 1000), 1)

        Logger.warning("Payment rate limit: bucket=#{name} ip=#{ip} retry_after=#{retry_after}s")

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

  @doc """
  Whether the connection was halted by a rate limit, so callers can tell a
  refusal apart from a pass-through.
  """
  def limited?(%Plug.Conn{halted: true, status: 429}), do: true
  def limited?(_), do: false

  # Fly sets fly-client-ip at its proxy, so a caller cannot spoof it.
  # x-forwarded-for can be spoofed, so it is only a fallback for non-Fly
  # deployments, and remote_ip is the last resort.
  @doc """
  The caller's address: Fly's client IP header, then the first X-Forwarded-For
  hop, then the socket. Public so every per-IP limit resolves it the same way.
  """
  def client_ip(conn) do
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
