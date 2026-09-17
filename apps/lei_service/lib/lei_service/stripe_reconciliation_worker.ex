defmodule LeiService.StripeReconciliationWorker do
  @moduledoc """
  Compares the ledger's purchases with Stripe's payments, hourly
  (`Lei.StripeReconciliation`, #139).

  A run that finds discrepancies, or cannot compare, still completes: the
  outcome is recorded and reported on `/metrics`. Retrying a failed comparison
  within the hour would only hide how often Stripe could not be reached.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _run} = Lei.StripeReconciliation.run()
    :ok
  end
end
