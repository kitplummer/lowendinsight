defmodule LeiService.DeployReportingTest do
  @moduledoc """
  A deploy run that ships nothing must not read like one that did (#259).

  The `deploy` workflow concludes `success` when it deliberately deploys
  nothing. Two merges landing close together finish CI in either order, and the
  gate refuses to deploy a commit main has already moved past — correctly,
  since deploying the older one would put production back a version. GitHub
  does not let a workflow choose its own conclusion, so declining and shipping
  are identical in the run list:

      run 35567530799  657755e  success   <- Deploy and verify: SKIPPED
      run 35552617402  657755e  success   <- Deploy and verify: success

  Reading the run conclusion as "deployed" produced two wrong answers in one
  sitting on 2026-09-20.

  None of this can be tested by running the workflow, so the artefacts are
  asserted: that the gate writes which decision it made where a reader is
  looking, and that the script answering "did this deploy?" reads the job
  rather than the run.
  """
  use ExUnit.Case, async: true
  import Bitwise

  @workflow Path.expand("../../../../.github/workflows/deploy.yml", __DIR__)
  @script Path.expand("../../../../scripts/ops/deploy-status.sh", __DIR__)
  @operations Path.expand("../../docs/OPERATIONS.md", __DIR__)

  describe "the run page says what happened" do
    test "the gate announces a decline, in the summary rather than only the log" do
      # A ::notice:: is easy to miss and does not appear at the top of the run
      # page. The job summary does.
      workflow = File.read!(@workflow)

      assert workflow =~ "DECLINED — nothing was shipped by this run",
             "a run that declined does not say so where anyone looks"

      assert workflow =~ "GITHUB_STEP_SUMMARY"
    end

    test "and announces a ship, so the two are distinguishable" do
      workflow = File.read!(@workflow)

      assert workflow =~ "### SHIPPING"
      assert workflow =~ "### SHIPPED"
    end

    test "the shipped line is written by the deploy job, not the gate" do
      # The gate only decides. A summary claiming a ship must come from the job
      # that reached the end, or a declined run would claim to have shipped.
      workflow = File.read!(@workflow)

      [_before, after_gate] = String.split(workflow, "name: Deploy and verify", parts: 2)

      assert after_gate =~ "### SHIPPED",
             "the shipped confirmation is not inside the job that does the deploying"
    end

    test "the run list carries the commit each run considered" do
      assert File.read!(@workflow) =~ "run-name:"
    end
  end

  describe "the question is answerable without reading a run page" do
    test "the script exists and is executable" do
      assert File.exists?(@script)
      %File.Stat{mode: mode} = File.stat!(@script)
      assert (mode &&& 0o100) != 0, "deploy-status.sh is not executable"
    end

    test "it reads the job conclusion, not the run conclusion" do
      # The whole point. A run concludes success when it declines.
      script = File.read!(@script)

      assert script =~ "select(.name==",
             "the script does not select a job by name"

      assert script =~ "JOB=\"Deploy and verify\""
    end

    test "a skipped job is reported as not deployed" do
      script = File.read!(@script)

      assert script =~ "declined, shipped nothing",
             "a skipped deploy job is not distinguished from one that shipped"
    end

    test "could not tell is never reported as deployed" do
      # The failure this replaces: an unreadable state read as success.
      script = File.read!(@script)

      assert script =~ "COULD NOT TELL"
      assert script =~ "never reported as deployed" or script =~ "is never reported as deployed"
    end
  end

  describe "running it, with gh stubbed" do
    # Source assertions cannot catch a behavioural change in the script, so the
    # decisions are exercised with `gh` replaced on PATH -- the approach
    # verify_webhook_script_test.exs takes for `stripe` and `curl`.
    setup do
      dir = Path.join(System.tmp_dir!(), "deploystatus-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "bin"))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp stub_gh(dir, job_conclusion, opts \\ []) do
      ci = Keyword.get(opts, :ci, "completed success")
      runs = Keyword.get(opts, :runs, "111")

      File.write!(Path.join(dir, "bin/gh"), """
      #!/usr/bin/env bash
      args="$*"

      case "$args" in
        *"--workflow umbrella_ci"*) echo "#{ci}" ;;
        *"--workflow deploy"*)      #{if runs == "", do: "true", else: "printf '%s\\n' #{runs}"} ;;
        *"--json jobs"*)            echo "#{job_conclusion}" ;;
        *"--json conclusion"*)      echo "success" ;;
        *) echo "" ;;
      esac
      exit 0
      """)

      File.chmod!(Path.join(dir, "bin/gh"), 0o755)
    end

    defp run_status(dir, sha) do
      System.cmd("bash", [@script, sha],
        env: [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}],
        stderr_to_stdout: true
      )
    end

    @sha "0123456789012345678901234567890123456789"

    test "a job that succeeded is deployed", %{dir: dir} do
      stub_gh(dir, "success")

      {out, code} = run_status(dir, @sha)

      assert out =~ "DEPLOYED"
      assert code == 0
    end

    test "a job that was skipped is NOT deployed", %{dir: dir} do
      # The whole point. The run concludes success; the job did not run, so
      # production is still on the previous version.
      stub_gh(dir, "skipped")

      {out, code} = run_status(dir, @sha)

      assert out =~ "declined, shipped nothing"
      refute out =~ "is live", "a declined deploy was reported as live"
      assert code == 1, "a declined deploy was reported as a successful one"
    end

    test "a job that failed is not deployed", %{dir: dir} do
      stub_gh(dir, "failure")

      {_out, code} = run_status(dir, @sha)
      assert code == 1
    end

    test "no deploy run at all is not deployed", %{dir: dir} do
      stub_gh(dir, "success", runs: "")

      {out, code} = run_status(dir, @sha)

      assert out =~ "no run for this commit"
      assert code == 1
    end

    test "an unreadable job state is could-not-tell, never deployed", %{dir: dir} do
      # An answer it cannot produce must not be the reassuring one.
      stub_gh(dir, "")

      {out, code} = run_status(dir, @sha)

      assert out =~ "COULD NOT TELL"
      refute out =~ "is live", "an unreadable state was reported as live"
      assert code == 2
    end
  end

  describe "the monitor notices an undeployed tip" do
    # A deploy that declined ships nothing and fails nowhere: the gate is
    # satisfied, CI is green, the run concludes success, and every other check
    # in the monitor passes because everything they test is fine. This is the
    # only thing that would notice (#259).
    @monitor Path.expand("../../../../.github/workflows/monitor.yml", __DIR__)

    test "the monitor checks whether the tip of main is live" do
      monitor = File.read!(@monitor)

      assert monitor =~ "Check the tip of main is deployed",
             "nothing notices a deploy that declined and shipped nothing"

      assert monitor =~ "scripts/ops/deploy-status.sh",
             "the monitor does not use the tool that reads the job rather than the run"
    end

    test "it fails rather than notes, once past the grace" do
      # A ::notice:: is not a page. An undeployed tip after the grace has to
      # fail the check or nothing wakes anyone.
      monitor = File.read!(@monitor)

      # Pinned to ::error:: specifically. Asserting the message text alone
      # passes when the severity is downgraded to ::notice::, which is the
      # difference between paging and not.
      assert monitor =~ "::error::${TIP:0:7} has been the tip of main",
             "an undeployed tip does not produce an error, so nothing pages"
    end

    test "a deploy in flight is not paged for" do
      # CI takes minutes and the deploy takes minutes more. Paging on a commit
      # merged moments ago would be noise, and noise gets ignored.
      monitor = File.read!(@monitor)

      # The value, not the variable: GRACE=0 satisfies "GRACE=" and pages on
      # every merge.
      assert monitor =~ "GRACE=$(( 30 * 60 ))",
             "the grace period is not a real duration, so every merge pages until it ships"
    end

    test "an answer it could not get is not a reassuring one" do
      monitor = File.read!(@monitor)

      assert monitor =~ "Could not determine whether",
             "an unreadable deploy state passes silently"
    end

    test "a failure names itself in the page" do
      # The aggregation lists failed checks by name. A step missing from it
      # pages as "unidentified", which says something is wrong and not what.
      monitor = File.read!(@monitor)

      assert monitor =~ "DEPLOYED: ${{ steps.deployed.outcome }}",
             "the deployed check is not collected for the page"

      assert monitor =~ ~s("deployed:$DEPLOYED"),
             "the deployed check is not named in the failure list"
    end
  end

  describe "it is written down" do
    test "OPERATIONS.md says a green run does not mean a deploy" do
      ops = File.read!(@operations)

      assert ops =~ "A green deploy run does not mean a deploy happened",
             "the runbook does not warn about the ambiguity"

      assert ops =~ "deploy-status.sh",
             "the runbook does not point at the script that answers it"
    end
  end
end
