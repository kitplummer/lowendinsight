defmodule Lei.TQM do
  @moduledoc """
  Total Quality Management for batch analysis runs.

  Tracks batch success rates in a sliding window and implements a
  circuit breaker that halts further batch runs when the rate drops
  below the configured threshold.

  The circuit opens when:
  - At least `min_sample` outcomes are in the current window
  - Success rate < `threshold` (default 50%)

  The circuit auto-resets to closed after `reset_after_ms` (default 5 minutes),
  allowing runs to resume once the window has aged out.

  Configuration options (passed to `start_link/1`):
  - `:window_size`    - sliding window size (default 10)
  - `:threshold`      - minimum acceptable success rate, 0.0–1.0 (default 0.5)
  - `:min_sample`     - minimum window count before circuit can open (default 1)
  - `:reset_after_ms` - ms after opening before auto-reset (default 300_000)
  - `:name`           - registered name (default `Lei.TQM`)
  """

  use GenServer

  @default_window_size 10
  @default_threshold 0.5
  @default_min_sample 1
  @default_reset_after_ms 5 * 60 * 1_000

  defstruct outcomes: [],
            window_size: @default_window_size,
            threshold: @default_threshold,
            min_sample: @default_min_sample,
            reset_after_ms: @default_reset_after_ms,
            circuit_opened_at: nil,
            total_runs: 0,
            total_successes: 0

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Record a successful batch run."
  def record_success(server \\ __MODULE__) do
    GenServer.cast(server, {:record, :ok})
  end

  @doc "Record a failed batch run."
  def record_failure(server \\ __MODULE__) do
    GenServer.cast(server, {:record, :error})
  end

  @doc "Returns `:open` when batch runs are halted, `:closed` otherwise."
  def circuit_state(server \\ __MODULE__) do
    GenServer.call(server, :circuit_state)
  end

  @doc "Returns a map describing current TQM state for observability."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      window_size: Keyword.get(opts, :window_size, @default_window_size),
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      min_sample: Keyword.get(opts, :min_sample, @default_min_sample),
      reset_after_ms: Keyword.get(opts, :reset_after_ms, @default_reset_after_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record, outcome}, state) do
    outcomes = [outcome | state.outcomes] |> Enum.take(state.window_size)
    total_runs = state.total_runs + 1
    total_successes = state.total_successes + if outcome == :ok, do: 1, else: 0

    new_state = %{
      state
      | outcomes: outcomes,
        total_runs: total_runs,
        total_successes: total_successes
    }

    {:noreply, maybe_open_circuit(new_state)}
  end

  @impl true
  def handle_call(:circuit_state, _from, state) do
    state = maybe_reset_circuit(state)
    result = if state.circuit_opened_at, do: :open, else: :closed
    {:reply, result, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    state = maybe_reset_circuit(state)
    success_rate = compute_success_rate(state.outcomes)

    result = %{
      circuit: if(state.circuit_opened_at, do: "open", else: "closed"),
      circuit_opened_at: state.circuit_opened_at,
      window_size: state.window_size,
      window_count: length(state.outcomes),
      success_rate: Float.round(success_rate * 100, 1),
      threshold_pct: Float.round(state.threshold * 100, 1),
      total_runs: state.total_runs,
      total_successes: state.total_successes
    }

    {:reply, result, state}
  end

  # --- Private ---

  defp maybe_open_circuit(%{circuit_opened_at: opened} = state) when not is_nil(opened) do
    # Already open; don't re-open
    state
  end

  defp maybe_open_circuit(state) do
    rate = compute_success_rate(state.outcomes)

    if length(state.outcomes) >= state.min_sample and rate < state.threshold do
      %{state | circuit_opened_at: System.monotonic_time(:millisecond)}
    else
      state
    end
  end

  defp maybe_reset_circuit(%{circuit_opened_at: nil} = state), do: state

  defp maybe_reset_circuit(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.circuit_opened_at >= state.reset_after_ms do
      %{state | circuit_opened_at: nil, outcomes: []}
    else
      state
    end
  end

  defp compute_success_rate([]), do: 1.0

  defp compute_success_rate(outcomes) do
    successes = Enum.count(outcomes, &(&1 == :ok))
    successes / length(outcomes)
  end
end
