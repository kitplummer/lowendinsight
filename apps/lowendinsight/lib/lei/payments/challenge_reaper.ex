defmodule Lei.Payments.ChallengeReaper do
  @moduledoc """
  Removes payment challenges that expired without being answered.

  An agent asking the price and walking away is normal, and every one of those
  writes a row. Without this they accumulate for as long as the service runs --
  a table that only grows, holding nothing anyone will read.

  Settled challenges are kept: they are the record that a payment was asked for
  and answered, and they are what makes "issued and never paid" a number rather
  than a guess.
  """

  use GenServer

  require Logger

  alias Lei.Payments.ChallengeStore

  # Hourly. Challenges expire in five minutes, so this is not about promptness
  # -- nothing depends on an expired row being gone. It is about the table not
  # growing without bound, and an hourly sweep is enough for that while costing
  # one query.
  @interval_ms :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)

    # Not on boot: the first sweep waits a full interval so a restart loop
    # cannot turn into a query loop.
    schedule(interval)

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:purge, state) do
    purge()
    schedule(state.interval)
    {:noreply, state}
  end

  # Anything else is ignored rather than crashing the reaper. Nothing depends
  # on this process, and taking the supervision tree down over an unexpected
  # message would be a worse outcome than a stale row.
  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Purges now. Exposed for tests and for an operator who wants it done.
  """
  def purge do
    count = ChallengeStore.purge_expired()

    if count > 0 do
      Logger.info("Purged #{count} expired payment challenge(s)")
    end

    count
  rescue
    error ->
      # A failed sweep is not worth restarting for. The rows are harmless and
      # the next sweep will try again.
      Logger.warning("Could not purge expired payment challenges: #{inspect(error)}")
      0
  end

  defp schedule(interval), do: Process.send_after(self(), :purge, interval)
end
