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

  defp trigger, do: File.read!(Path.join(@workflows, "backup-trigger.yml"))
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

      assert src =~ ~r/while \[ "\$AFTER" = "\$BEFORE" \]/,
             "the wait is not on a new exit event, so it can read a previous run's result"

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
end
