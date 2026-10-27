defmodule LeiService.Plugs.RateLimiter do
  @moduledoc """
  The per-key allowance on the analysis routes this endpoint serves itself.

  One allowance per API key, the one its org's tier has (`:rate_limits` --
  60 a minute free, 600 Pro), drawn on by every analysis route. It is the
  `api:` bucket `Lei.Auth` already charges `POST /v1/analyze/batch` to, so a
  key does not get one allowance per route.

  This was a limiter of its own: 10 a minute whatever the tier, written before
  there were tiers, on `POST /v1/analyze` only -- it matched that path exactly,
  so `/v1/analyze/sbom` had no per-key limit at all -- while the signup page
  promised 60 (2026-10-27).

  The batch route is not counted here: it is forwarded to `Lei.Web.Router`,
  whose `Lei.Auth` counts it, and counting it twice would halve it. Signed
  operator tokens and unauthenticated requests are not counted; the payment
  gate decides what happens to the latter.
  """
  import Plug.Conn
  require Logger

  @limited ["/v1/analyze", "/v1/analyze/sbom"]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: path, halted: false} = conn, _opts)
      when path in @limited do
    case conn.assigns[:current_api_key] do
      nil -> conn
      api_key -> check_rate(conn, api_key)
    end
  end

  def call(conn, _opts), do: conn

  @doc "Clear all rate limit state (useful in tests)."
  def clear, do: Lei.RateLimiter.clear()

  defp check_rate(conn, api_key) do
    case Lei.RateLimiter.check("api:#{api_key.key_prefix}", api_key.org.tier) do
      {:ok, remaining} ->
        put_resp_header(conn, "x-ratelimit-remaining", to_string(remaining))

      {:error, :rate_limited, retry_after_ms} ->
        retry_secs = Lei.RateLimiter.retry_after_seconds(retry_after_ms)

        Logger.warning(
          "[RateLimiter] rate limit exceeded: key_prefix=#{api_key.key_prefix} retry_after=#{retry_secs}s"
        )

        conn
        |> put_resp_header("retry-after", to_string(retry_secs))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Poison.encode!(%{error: "rate limit exceeded", retry_after: retry_secs})
        )
        |> halt()
    end
  end
end
