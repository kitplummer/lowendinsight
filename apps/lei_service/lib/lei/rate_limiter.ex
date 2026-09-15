defmodule Lei.RateLimiter do
  @moduledoc """
  ETS-based sliding window rate limiter.
  """
  use GenServer

  @table :lei_rate_limiter
  @default_window_ms 60_000
  @default_limits %{free: 60, pro: 600}
  @cleanup_interval_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(key, tier \\ "free") do
    now = System.monotonic_time(:millisecond)
    window = window_for(tier)
    limit = limit_for(tier)
    cutoff = now - window

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
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

  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp window_ms do
    Application.get_env(:lei_service, :rate_limit_window_ms, @default_window_ms)
  end

  # A bucket may count over a longer window than the default minute -- the Try
  # It form is limited per hour (#152). Buckets without an entry use the default.
  defp window_for(tier) do
    windows = Application.get_env(:lei_service, :rate_limit_windows, %{})
    Map.get(windows, String.to_existing_atom(tier), window_ms())
  rescue
    ArgumentError -> window_ms()
  end

  defp longest_window do
    :lei_service
    |> Application.get_env(:rate_limit_windows, %{})
    |> Map.values()
    |> Enum.max(fn -> 0 end)
    |> max(window_ms())
  end

  defp limit_for(tier) do
    limits = Application.get_env(:lei_service, :rate_limits, @default_limits)
    Map.get(limits, String.to_existing_atom(tier), @default_limits.free)
  rescue
    ArgumentError -> @default_limits.free
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    # The longest window any bucket counts over. Cutting at the default minute
    # would erase an hourly bucket's history every two minutes, and the limit
    # would never be reached.
    cutoff = now - longest_window()

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
