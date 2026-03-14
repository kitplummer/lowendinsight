defmodule Lei.Web.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug for the /v1/analyze endpoint.

  Enforces a fixed limit of 10 requests per minute per API key (or per IP
  address for unauthenticated callers). Uses a sliding window algorithm backed
  by an ETS table.

  Returns 429 Too Many Requests with a `Retry-After` header when the limit is
  exceeded, and logs a warning for every rejected request.
  """

  import Plug.Conn
  require Logger

  @table :lei_analyze_rate_limiter
  @window_ms 60_000
  @default_limit 10

  @doc """
  Plug init — ensures the ETS backing table exists and resolves the configured
  per-minute limit (default: #{@default_limit}).
  """
  def init(opts) do
    ensure_table()
    Keyword.put_new(opts, :limit, @default_limit)
  end

  @doc """
  Plug call — applies rate limiting to requests whose path starts with
  `/v1/analyze`. All other paths pass through unchanged.
  """
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{request_path: path} = conn, opts) do
    if String.starts_with?(path, "/v1/analyze") do
      limit = Keyword.get(opts, :limit, @default_limit)
      key = rate_limit_key(conn)

      case check(key, limit) do
        {:ok, _remaining} ->
          conn

        {:error, :rate_limited, retry_after_ms} ->
          retry_secs = div(retry_after_ms, 1_000) + 1
          Logger.warning("Rate limit exceeded for #{key}, retry_after: #{retry_secs}s")

          conn
          |> put_resp_header("retry-after", to_string(retry_secs))
          |> put_resp_content_type("application/json")
          |> send_resp(429, Poison.encode!(%{error: "rate limit exceeded", retry_after: retry_secs}))
          |> halt()
      end
    else
      conn
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers (also used by tests)
  # ---------------------------------------------------------------------------

  @doc "Check whether *key* is within *limit* requests in the current window."
  def check(key, limit \\ @default_limit) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 > cutoff))
        count = length(recent)

        if count < limit do
          :ets.insert(@table, {key, [now | recent]})
          {:ok, limit - count - 1}
        else
          oldest = Enum.min(recent)
          retry_after = oldest + @window_ms - now
          {:error, :rate_limited, max(retry_after, 0)}
        end

      [] ->
        :ets.insert(@table, {key, [now]})
        {:ok, limit - 1}
    end
  end

  @doc "Reset state for a specific key (useful in tests)."
  def reset(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc "Clear all rate limit state."
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rate_limit_key(conn) do
    case conn.assigns[:current_api_key] do
      %{key_prefix: prefix} -> "analyze:#{prefix}"
      nil -> "analyze:ip:#{remote_ip(conn)}"
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, :set])
  rescue
    ArgumentError -> :ok
  end
end
