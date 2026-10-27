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

    # 2026-10-24: hex.pm returned 500 to one `mix deps.get`, umbrella_ci failed
    # on 03743c5, and the deploy gate declined it. The monitor's error said only
    # "not deployed" for seven hours; the CI failure that explained it was three
    # lookups away. When CI failed on the commit, that is the answer, and it
    # comes with the command that resolves a transient failure.
    test "a commit CI failed on says so, with the run to re-run", %{dir: dir} do
      stub_gh(dir, "skipped", ci: "completed failure 4242")

      {out, code} = run_status(dir, @sha)

      assert code == 1
      assert out =~ ~r/NOT DEPLOYED: .*umbrella_ci failed on this commit \(run 4242\)/
      assert out =~ "gh run rerun 4242 --failed"
    end

    test "and says so when no deploy run was triggered at all", %{dir: dir} do
      stub_gh(dir, "skipped", ci: "completed failure 4242", runs: "")

      {out, 1} = run_status(dir, @sha)

      assert out =~ "umbrella_ci failed on this commit (run 4242)"
    end

    test "a commit CI passed on is not blamed on CI", %{dir: dir} do
      stub_gh(dir, "skipped", ci: "completed success 4242")

      {out, 1} = run_status(dir, @sha)

      refute out =~ "umbrella_ci failed"
    end

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

    # 2026-10-27 16:13: the monitor failed with "could not determine whether
    # d1b0223 is deployed". The deploy run it asked about had finished fourteen
    # hours earlier, and the same script a few minutes later said DEPLOYED. One
    # `gh run view` failed, its stderr went to /dev/null, and a failed read was
    # reported exactly like a job that does not exist yet.
    defp stub_gh_flaky(dir, failures) do
      count = Path.join(dir, "jobs_calls")

      File.write!(Path.join(dir, "bin/gh"), """
      #!/usr/bin/env bash
      case "$*" in
        *"--workflow umbrella_ci"*) echo "completed success 4242" ;;
        *"--workflow deploy"*)      echo "111" ;;
        *"--json jobs"*)
          n=$(( $(cat #{count} 2>/dev/null || echo 0) + 1 )); echo "$n" > #{count}
          if [ "$n" -le #{failures} ]; then
            echo "HTTP 502: Bad Gateway (https://api.github.com/repos/x/y/actions/runs/111)" >&2
            exit 1
          fi
          echo "success" ;;
        *"--json conclusion"*)      echo "success" ;;
      esac
      """)

      File.chmod!(Path.join(dir, "bin/gh"), 0o755)
    end

    defp run_status_now(dir, sha) do
      System.cmd("bash", [@script, sha],
        env: [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"DEPLOY_STATUS_RETRY_DELAY", "0"}
        ],
        stderr_to_stdout: true
      )
    end

    test "one failed read of a finished run is retried, not reported", %{dir: dir} do
      stub_gh_flaky(dir, 1)

      {out, code} = run_status_now(dir, @sha)

      assert code == 0, "a single failed gh call was reported as could-not-tell:\n#{out}"
      assert out =~ "DEPLOYED"
    end

    test "a read that keeps failing is could-not-tell, and says why", %{dir: dir} do
      stub_gh_flaky(dir, 99)

      {out, code} = run_status_now(dir, @sha)

      assert code == 2
      assert out =~ "COULD NOT TELL"
      refute out =~ "is live"
      assert out =~ "HTTP 502", "gh's own error was discarded, so the failure cannot be diagnosed"
    end

    test "deploy runs that cannot be listed are could-not-tell, not none", %{dir: dir} do
      File.write!(Path.join(dir, "bin/gh"), """
      #!/usr/bin/env bash
      case "$*" in
        *"--workflow umbrella_ci"*) echo "completed success 4242" ;;
        *"--workflow deploy"*)      echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
      esac
      """)

      File.chmod!(Path.join(dir, "bin/gh"), 0o755)

      {out, code} = run_status_now(dir, @sha)

      assert code == 2, "a failed listing was read as no deploy run:\n#{out}"
      refute out =~ "no run for this commit"
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

    test "the error carries deploy-status.sh's verdict, which names a CI failure" do
      # The verdict was in the log and not in the annotation -- the part that
      # is on the run page and in the email.
      monitor = File.read!(@monitor)

      assert monitor =~ ~r/::error::\$\{TIP:0:7\} has been the tip of main[^"]*\$\{VERDICT\}"/,
             "the undeployed-tip error does not say why"
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

    # Merging #277 turned the monitor red four minutes later, and emailed about
    # it. The deploy run for the merge commit had existed for eight seconds, so
    # its `Deploy and verify` job had not been created yet, deploy-status.sh
    # answered "could not tell" (exit 2), and the grace period was only ever
    # applied to "not deployed" (exit 1). Every merge produced a red run and a
    # page-shaped email from the one check whose job is noticing an undeployed
    # tip -- which is how an alarm stops being read.
    test "a deploy whose job state is not readable yet is within the grace" do
      monitor = File.read!(@monitor)

      # Both outcomes share the grace: 1 is "no run, or every run declined",
      # 2 is "a run exists but its job has not started". In the first minutes
      # after a merge either is normal.
      assert monitor =~ ~r/^\s*1\|2\)/m,
             "only 'not deployed' gets the grace, so a deploy in flight fails the run"

      refute monitor =~
               ~r/::error::Could not determine whether \$\{TIP:0:7\} is deployed\.\n\s*exit 1/,
             "an unreadable state fails immediately, before the grace is considered"
    end

    # The other half of the same rule: inside the grace it is too early to tell,
    # outside it, not knowing is not the same as fine.
    test "an unreadable deploy state still fails once the grace has passed" do
      monitor = File.read!(@monitor)

      assert monitor =~ "Not knowing is not the same as fine",
             "an answer we could not get reads as reassuring after the grace"

      assert monitor =~ ~r/Could not determine whether[^\n]*after it became the tip/,
             "the failure does not say how long it has been unreadable"
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
