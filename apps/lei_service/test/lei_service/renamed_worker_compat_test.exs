defmodule LeiService.RenamedWorkerCompatTest do
  @moduledoc """
  A job Oban stored under the worker's pre-rename name still runs.

  Oban records a job's worker as a module name. The service app was renamed
  from lowendinsight_get to lei_service (ADR-003); a job enqueued or retrying
  as `LowendinsightGet.AnalysisWorker` when that deployed would otherwise fail
  to resolve its worker.
  """
  use ExUnit.Case, async: true

  test "the old worker name resolves to a worker that runs the new one" do
    assert {:ok, LowendinsightGet.AnalysisWorker} =
             Oban.Worker.from_string("LowendinsightGet.AnalysisWorker")

    assert {:ok, LeiService.AnalysisWorker} = Oban.Worker.from_string("LeiService.AnalysisWorker")

    source = File.read!(Path.join(File.cwd!(), "lib/lei_service/compat/old_analysis_worker.ex"))
    assert source =~ "LeiService.AnalysisWorker.perform(job)"
  end
end
