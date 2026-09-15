defmodule LowendinsightGet.AnalysisWorker do
  @moduledoc """
  The analysis worker's name before the service app was renamed to lei_service
  (ADR-003).

  Oban stores a job's worker as a module name. A job enqueued or retrying under
  the old name when the rename deploys would otherwise fail with "worker not
  found". This delegates to `LeiService.AnalysisWorker`. Remove it once no
  `oban_jobs` row names `LowendinsightGet.AnalysisWorker`.
  """
  use Oban.Worker, queue: :analysis

  @impl Oban.Worker
  def perform(job), do: LeiService.AnalysisWorker.perform(job)
end
