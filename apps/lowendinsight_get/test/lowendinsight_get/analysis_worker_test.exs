defmodule LowendinsightGet.AnalysisWorkerTest do
  use ExUnit.Case, async: false

  setup do
    Redix.command(:redix, ["FLUSHDB"])

    on_exit(fn ->
      Task.Supervisor.children(LowendinsightGet.AnalysisSupervisor)
      |> Enum.map(fn child ->
        Task.Supervisor.terminate_child(LowendinsightGet.AnalysisSupervisor, child)
      end)
    end)
  end

  @tag timeout: 180_000
  test "perform/1 processes analysis and writes job result" do
    uuid = UUID.uuid1()
    url = "https://github.com/kitplummer/goa"
    start_time = DateTime.utc_now()

    # Clear cache for this URL
    key = LowendinsightGet.Datastore.cache_key(url)
    Redix.command(:redix, ["DEL", key])

    job = %Oban.Job{
      args: %{
        "uuid" => uuid,
        "urls" => [url],
        "start_time" => DateTime.to_iso8601(start_time)
      }
    }

    assert :ok == LowendinsightGet.AnalysisWorker.perform(job)

    # Verify job was written to Redis
    {:ok, result} = LowendinsightGet.Datastore.get_job(uuid)
    parsed = Poison.decode!(result)
    assert parsed["state"] == "complete"
    assert length(parsed["report"]["repos"]) == 1
  end
end
