defmodule LeiService.BackupTriggerTest do
  @moduledoc """
  Something has to start the producer, and it is not Fly.

  The machine was created with `--schedule daily` on 2026-09-26 and recreated on
  2026-09-27 with `--restart on-failure`, which is Fly's own default for a
  scheduled machine. In neither configuration did flyd ever start it: every
  start event in its history has `SOURCE=user`, a human forcing one. Two days,
  three configurations, no scheduled run.

  ADR-006 inferred that `--restart no` was the cause. That theory did not
  survive: `on-failure` did not fire either.

  So the schedule moves somewhere observable. `backup-trigger.yml` starts the
  machine and waits for the result, which is a job that either ran or did not,
  with a page when it fails. CI still does not take the backup -- it holds no
  database credentials and no bucket write key. It says "run now" to a producer
  that does the work with its own.
  """
  use ExUnit.Case, async: true

  @workflows Path.expand("../../../../.github/workflows", __DIR__)

  @trigger_script Path.expand("../../../../scripts/ops/backup-trigger.sh", __DIR__)

  # The workflow and the script it runs, read as one.
  defp trigger,
    do: File.read!(Path.join(@workflows, "backup-trigger.yml")) <> File.read!(@trigger_script)

  defp verify, do: File.read!(Path.join(@workflows, "backup.yml"))

  describe "it runs on its own" do
    test "it is scheduled, and before the verification that checks it" do
      # A trigger that runs after the check it feeds leaves the check reading
      # yesterday's object and failing on staleness for a day.
      assert trigger() =~ ~r/cron:\s*'[^']+'/, "the trigger has no schedule"

      [_, trig_h] = Regex.run(~r/cron: '\d+ (\d+) \* \* \*'/, trigger())
      [_, ver_h] = Regex.run(~r/cron: '\d+ (\d+) \* \* \*'/, verify())

      assert String.to_integer(trig_h) < String.to_integer(ver_h),
             "the producer is triggered at #{trig_h}:00 and verified at #{ver_h}:00, so the check reads the previous day's backup"
    end

    test "it can be run by hand" do
      assert trigger() =~ "workflow_dispatch",
             "the producer cannot be started from the Actions tab when it matters"
    end
  end

  describe "it does not report success for a run it did not watch" do
    test "it waits for a new exit event, not for a state" do
      # `flyctl machine start` returns as soon as the machine is starting, and
      # the machine's resting state is already `stopped`. A loop that waits for
      # "stopped" is satisfied by the state it began in, and then reads the
      # *previous* run's exit code -- so a prior success would mask a fresh
      # failure. The condition has to be a new exit event.
      src = trigger()

      assert src =~ "machine status",
             "nothing reads the outcome of the run it started"

      assert src =~ ~s([ "$AFTER" -gt "$BEFORE" ]),
             "the wait is not on a newer exit event, so it can read a previous run's result"

      assert src =~ "select(.type == \"exit\")",
             "exit events are not what is being watched"

      refute src =~ ~r/while \[ "\$STATE" != "stopped" \]/,
             "the wait is on a state the machine was already in"
    end

    test "it reads the exit code and requires zero" do
      # backup.sh exits non-zero on every failure it can detect: an empty dump,
      # an unreadable one, an artifact that will not decrypt, an upload that did
      # not land.
      assert trigger() =~ "exit_code=",
             "the run's exit code is never read"

      assert trigger() =~ ~s(sed -n 's/.*exit_code=),
             "the exit code is mentioned but never extracted"

      assert trigger() =~ ~s("$CODE" != "0"),
             "the extracted exit code is never compared against success"
    end

    test "an outcome it could not read is a failure" do
      assert trigger() =~ "::error::",
             "the trigger cannot fail"

      refute trigger() =~ ~r/\|\|\s*true\s*$/m,
             "a step swallows its own failure"
    end

    test "it finds the machine rather than hardcoding an id" do
      # The machine has been recreated four times in two days -- every secret
      # change needs a new one, because a machine takes its secrets at creation.
      # A hardcoded id is a trigger that silently starts nothing.
      refute trigger() =~ ~r/\b[0-9a-f]{14}\b/,
             "a machine id is hardcoded, and machines are recreated whenever a secret changes"

      assert trigger() =~ "machine list",
             "the machine is not discovered"
    end
  end

  describe "a failure reaches a person" do
    test "it pages" do
      assert trigger() =~ "scripts/notify.sh",
             "a producer that did not run is silent until the next verification"

      assert trigger() =~ "if: failure()"
    end

    test "it checks out the repository that holds the script" do
      assert trigger() =~ "actions/checkout"
    end
  end

  describe "it is still not the thing taking the backup" do
    test "CI holds no database credentials and no bucket write key" do
      # ADR-006's separation: production takes the backup, CI checks it. A
      # trigger says "run now"; it does not dump anything.
      src = trigger()

      refute src =~ "PG_DUMP_URL", "the trigger holds the database credentials"
      refute src =~ "BACKUP_PASSPHRASE", "the trigger holds the encryption key"
      refute src =~ ~r/^\s*pg_dump/m, "the trigger takes the dump itself"
    end
  end

  describe "running it, with flyctl stubbed" do
    # Source assertions cannot catch a behavioural change, so the decisions are
    # exercised with `flyctl` replaced on PATH, as deploy_reporting_test.exs
    # does for `gh`.
    #
    # Each `machine list` call returns the next scripted answer, repeating the
    # last; FAIL makes that call exit 1. The first call is the script finding
    # the machine, the second its baseline. `machine status` reports an exit code
    # only once the scripted machine has exited.

    setup do
      dir = Path.join(System.tmp_dir!(), "backuptrigger-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "bin"))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp machine(exits), do: machine(exits, [])

    defp machine(exits, other) do
      events =
        Enum.map(exits, &%{"type" => "exit", "timestamp" => &1}) ++
          Enum.map(other, &%{"type" => &1, "timestamp" => 1})

      Jason.encode!([%{"id" => "m1", "config" => %{"schedule" => nil}, "events" => events}])
    end

    # lists: one answer per `machine list` call. exited_after: the call count
    # from which `machine status` carries exit_code=CODE.
    defp stub_flyctl(dir, lists, code, exited_after) do
      lists
      |> Enum.with_index(1)
      |> Enum.each(fn {body, i} -> File.write!(Path.join(dir, "list.#{i}"), body) end)

      File.write!(Path.join(dir, "bin/flyctl"), """
      #!/usr/bin/env bash
      d="#{dir}"
      case "$1 $2" in
        "machine list")
          n=$(( $(cat "$d/calls" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$d/calls"
          f="$d/list.$n"
          [ -f "$f" ] || f=$(ls "$d"/list.* | sort -t. -k2 -n | tail -1)
          [ "$(cat "$f")" = "FAIL" ] && exit 1
          cat "$f" ;;
        "machine start") echo "m1 has been started" ;;
        "machine status")
          n=$(cat "$d/calls" 2>/dev/null || echo 0)
          if [ "$n" -ge #{exited_after} ]; then
            echo "  exit  exit_code=#{code},oom_killed=false"
          else
            echo "  start  started"
          fi ;;
        *) exit 1 ;;
      esac
      """)

      File.chmod!(Path.join(dir, "bin/flyctl"), 0o755)
    end

    defp run_trigger(dir) do
      System.cmd("bash", [@trigger_script],
        env: [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"APP", "lowendinsight-backup"},
          {"FLY_API_TOKEN", "test-token"},
          {"BACKUP_POLL_SECONDS", "0"},
          {"BACKUP_WAIT_POLLS", "6"}
        ],
        stderr_to_stdout: true
      )
    end

    test "a successful run passes", %{dir: dir} do
      stub_flyctl(
        dir,
        [machine([1000]), machine([1000]), machine([1000]), machine([1000, 2000])],
        0,
        4
      )

      {out, code} = run_trigger(dir)
      assert code == 0, out
      assert out =~ "exited 0"
    end

    test "a list that has lost the old exit event is not the new one", %{dir: dir} do
      # 2026-11-06 and 2026-11-12: just after the start, the machine's events
      # no longer included an exit, so the newest exit read as 0. 0 differs
      # from the baseline, the wait ended after one poll, and the status was
      # read before the dump finished: "Could not read an exit code", while the
      # backup itself landed minutes later.
      stub_flyctl(
        dir,
        [
          machine([1000]),
          machine([1000]),
          machine([], ["launch", "start"]),
          machine([], ["start"]),
          machine([2000])
        ],
        0,
        5
      )

      {out, code} = run_trigger(dir)
      assert code == 0, out
      refute out =~ "Could not read an exit code"
    end

    test "a failed read while waiting is retried, not taken as the result", %{dir: dir} do
      stub_flyctl(dir, [machine([1000]), machine([1000]), "FAIL", machine([1000, 2000])], 0, 4)
      {out, code} = run_trigger(dir)
      assert code == 0, out
    end

    test "no new exit event is a failure", %{dir: dir} do
      stub_flyctl(dir, [machine([1000])], 0, 99)
      {out, code} = run_trigger(dir)
      assert code == 1
      assert out =~ "no new exit event"
    end

    test "a non-zero exit code is a failure", %{dir: dir} do
      stub_flyctl(dir, [machine([1000]), machine([1000]), machine([1000, 2000])], 1, 3)
      {out, code} = run_trigger(dir)
      assert code == 1
      assert out =~ "exited 1"
    end

    test "a baseline it cannot read is a failure, not a zero", %{dir: dir} do
      # With no baseline every exit event looks new, including the last run's.
      # Call 1 finds the machine; every read after it fails.
      stub_flyctl(dir, [machine([1000]), "FAIL"], 0, 3)
      {out, code} = run_trigger(dir)
      assert code == 1
      refute out =~ "exited 0"
    end
  end
end
