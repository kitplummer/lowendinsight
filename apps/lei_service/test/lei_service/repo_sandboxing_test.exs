defmodule LeiService.RepoSandboxingTest do
  @moduledoc """
  A test cannot commit to `LeiService.Repo` (#217).

  Oban writes through that repo, and it was the one repo the suite never put
  into manual sandbox mode. So every test that enqueued a job **committed** it,
  and six files left jobs behind on every run.

  What that cost was not a dirty table. Those jobs aged, and once they were
  older than `backlog_after_minutes` (15) the next run's readiness check
  reported the queue backed up -- failing `OpsRoutingTest`,
  `HealthEndpointsTest` and `HealthTest` in whichever run happened to come more
  than fifteen minutes after the last. **No seed ever reproduced it**, because
  the trigger was elapsed wall-clock time between runs rather than anything in
  the run itself. It was reproduced by aging the leftover rows by hand.

  The stopgap was `LeiService.Repo.delete_all("oban_jobs")` in `test_helper.exs`
  before every suite. A suite that tidies up after itself before it starts is
  describing a leak rather than preventing one, and it only hid the symptom:
  jobs still committed mid-run, so a test that read the queue could see another
  test's jobs within a single run.

  `async: false` deliberately. A test asserting that a process without
  ownership is refused would be wrong while a concurrent test holds the repo in
  `{:shared, owner}` mode; ExUnit runs every async test before any sync one, so
  nothing overlaps this.
  """
  use ExUnit.Case, async: false

  @helper Path.expand("../test_helper.exs", __DIR__)

  describe "at runtime" do
    # The assertion that matters. Under `:auto` -- the mode this repo was
    # effectively in -- an unowned process queries happily and its writes
    # commit. Under `:manual` it is refused, which is what makes a leak
    # impossible rather than merely tidied up afterwards.
    test "a process with no checkout cannot reach LeiService.Repo" do
      result =
        Task.async(fn ->
          try do
            LeiService.Repo.aggregate("oban_jobs", :count)
            :queried
          rescue
            DBConnection.OwnershipError -> :refused
          end
        end)
        |> Task.await()

      assert result == :refused,
             "LeiService.Repo answered a process that never checked it out, so a test " <>
               "that enqueues a job commits it (#217)"
    end

    test "Lei.Repo is sandboxed the same way, which it always was" do
      result =
        Task.async(fn ->
          try do
            Lei.Repo.aggregate("orgs", :count)
            :queried
          rescue
            DBConnection.OwnershipError -> :refused
          end
        end)
        |> Task.await()

      assert result == :refused
    end
  end

  describe "the helper that sets it" do
    test "puts both repos in manual mode" do
      helper = File.read!(@helper)

      assert helper =~ "Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, :manual)"
      assert helper =~ "Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, :manual)"
    end

    # The workaround and the fix are mutually exclusive: if the suite still
    # cleared the table, it would pass whether or not the sandbox worked, and
    # nobody would learn that it had stopped.
    test "no longer clears the jobs table to cover for a leak" do
      helper = File.read!(@helper)

      refute helper =~ ~r/delete_all\(["']oban_jobs["']\)/,
             "the suite still clears oban_jobs, which would mask the sandbox failing"
    end
  end
end
