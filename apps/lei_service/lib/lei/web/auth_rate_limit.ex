defmodule Lei.Web.AuthRateLimit do
  @moduledoc """
  Per-IP limits on the three unauthenticated account routes.

  All three must be reachable without credentials, so a limit is the only
  lever (the same reasoning as `Lei.Payments.RateLimit`):

    * `recover` -- a slug and a recovery code, answered with a **new admin API
      key**. The tightest bucket: unlimited guessing was a way to take over an
      organisation.
    * `login`   -- an API key. Unlimited guessing is credential stuffing.
    * `signup`  -- creates an organisation and a key, so unlimited signups are
      rows an unauthenticated caller can create at will.

  The attempt is counted before it is checked, so a correct guess costs the
  same as a wrong one; otherwise a run is limited only by its failures.
  """

  import Plug.Conn

  require Logger

  @buckets [:signup, :login, :recover]

  @spec check(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def check(conn, bucket) when bucket in @buckets do
    ip = Lei.Payments.RateLimit.client_ip(conn)
    name = Atom.to_string(bucket)

    case Lei.RateLimiter.check("auth:#{name}:#{ip}", name) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        retry_after = max(div(retry_after_ms, 1000), 1)

        # The address, never the credential attempted: a log line holding a
        # recovery code or an API key is the leak this route protects against.
        Logger.warning("Auth rate limit: bucket=#{name} ip=#{ip} retry_after=#{retry_after}s")

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(429, "Too many attempts. Try again in #{retry_after} seconds.")
        |> halt()
    end
  end
end
