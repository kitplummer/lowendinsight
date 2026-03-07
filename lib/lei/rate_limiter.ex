defmodule Lei.RateLimiter do
  @moduledoc """
  ETS-based sliding window rate limiter.

  Tracks request counts per key (API key prefix or IP) within a
  configurable window. Limits are tier-based: free keys get fewer
  requests per window than pro keys.
  """
  use GenServer

  @table :lei_rate_limiter
  @default_window_ms 60_000
  @default_limits %{free: 60, pro: 600}
  @cleanup_interval_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed under the rate limit.
  Returns {:ok, remaining} or {:error, :rate_limited, retry_after_ms}.
  """
  def check(key, tier \\ "free") do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    limit = limit_for(tier)
    cutoff = now - window

    # Get current count in window
    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        # Filter to only timestamps within window
        recent = Enum.filter(timestamps, &(&1 > cutoff))
        count = length(recent)

        if count < limit do
          :ets.insert(@table, {key, [now | recent]})
          {:ok, limit - count - 1}
        else
          oldest = Enum.min(recent)
          retry_after = oldest + window - now
          {:error, :rate_limited, max(retry_after, 0)}
        end

      [] ->
        :ets.insert(@table, {key, [now]})
        {:ok, limit - 1}
    end
  end

  @doc "Reset rate limit state for a key (useful in tests)."
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Clear all rate limit state."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp window_ms do
    Application.get_env(:lowendinsight, :rate_limit_window_ms, @default_window_ms)
  end

  defp limit_for(tier) do
    limits = Application.get_env(:lowendinsight, :rate_limits, @default_limits)
    Map.get(limits, String.to_existing_atom(tier), @default_limits.free)
  rescue
    ArgumentError -> @default_limits.free
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms()

    :ets.foldl(
      fn {key, timestamps}, _acc ->
        recent = Enum.filter(timestamps, &(&1 > cutoff))

        if Enum.empty?(recent) do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, recent})
        end
      end,
      nil,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
