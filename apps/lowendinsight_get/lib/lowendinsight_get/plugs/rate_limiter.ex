defmodule LowendinsightGet.Plugs.RateLimiter do
  @moduledoc """
  Sliding-window rate limiter Plug for POST /v1/analyze.

  Limits API key-authenticated requests to 10 per minute (configurable via
  `:lowendinsight_get, :analyze_rate_limit`). JWT-authenticated and unauthenticated
  requests are not rate limited here.

  Returns 429 Too Many Requests with a `retry-after` header (in seconds) when the
  limit is exceeded. Rate-limited requests are logged at the :warning level.
  """
  import Plug.Conn
  require Logger

  @table :lowendinsight_get_analyze_rl
  @default_limit 10
  @window_ms 60_000

  def init(opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    opts
  end

  def call(%Plug.Conn{request_path: "/v1/analyze", method: "POST"} = conn, _opts) do
    case conn.assigns[:current_api_key] do
      nil -> conn
      api_key -> check_rate(conn, api_key.key_prefix)
    end
  end

  def call(conn, _opts), do: conn

  @doc "Reset rate limit state for a specific key (useful in tests)."
  def reset(key), do: :ets.delete(@table, key)

  @doc "Clear all rate limit state (useful in tests)."
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
  end

  defp check_rate(conn, key) do
    limit = Application.get_env(:lowendinsight_get, :analyze_rate_limit, @default_limit)
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms

    timestamps =
      case :ets.lookup(@table, key) do
        [{^key, ts}] -> Enum.filter(ts, &(&1 > cutoff))
        [] -> []
      end

    count = length(timestamps)

    if count < limit do
      :ets.insert(@table, {key, [now | timestamps]})
      put_resp_header(conn, "x-ratelimit-remaining", to_string(limit - count - 1))
    else
      oldest = Enum.min(timestamps)
      retry_ms = oldest + @window_ms - now
      retry_secs = div(max(retry_ms, 0), 1000) + 1

      Logger.warning(
        "[RateLimiter] analyze rate limit exceeded: key_prefix=#{key} retry_after=#{retry_secs}s"
      )

      conn
      |> put_resp_header("retry-after", to_string(retry_secs))
      |> put_resp_content_type("application/json")
      |> send_resp(429, Poison.encode!(%{error: "rate limit exceeded", retry_after: retry_secs}))
      |> halt()
    end
  end
end
