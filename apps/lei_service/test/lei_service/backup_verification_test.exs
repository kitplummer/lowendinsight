defmodule LeiService.BackupVerificationTest do
  @moduledoc """
  The backup is produced near the data and verified here (ADR-006).

  Producing it on a GitHub runner put a WireGuard tunnel, `flyctl proxy`, a
  flyctl binary resolved as `latest` and the pgdg apt repository in the nightly
  path. Three of those failed in two weeks, from three unrelated causes, and on
  two of those nights the page that should have said so was rejected with a 401.

  Moving production into a scheduled Fly Machine trades those for one new
  failure mode, and it is a worse one if nothing watches for it: **a scheduled
  machine that stops running produces no failure anywhere**. No red run, no
  page, no log line. Only an object that did not arrive.

  So the assertions that matter here are about freshness and about restoring.
  Everything else this job does -- decrypting, listing a table of contents --
  would pass for a dump of an empty database taken a year ago.
  """
  use ExUnit.Case, async: true

  @workflows Path.expand("../../../../.github/workflows", __DIR__)
  @root Path.expand("../../../..", __DIR__)

  defp backup, do: File.read!(Path.join(@workflows, "backup.yml"))
  defp producer, do: File.read!(Path.join(@root, "ops/backup/backup.sh"))
  defp puller, do: File.read!(Path.join(@root, "scripts/backup-pull.sh"))

  describe "a producer that stopped is noticed" do
    test "the age of the newest object is compared against a real limit" do
      # The check the old design could not have: it took the backup, so
      # "the backup did not happen" and "the job failed" were the same event.
      # They are not the same event any more.
      assert backup() =~ ~r/LIMIT=\$\(\(\s*26 \* 3600\s*\)\)/,
             "no freshness limit, so a producer that stopped looks exactly like one that ran"

      assert backup() =~ ~r/"\$AGE" -gt "\$LIMIT"/,
             "an age is computed but never compared"

      assert backup() =~ "The producer has stopped",
             "the failure does not say what it means"
    end

    test "a missing pointer is a failure, not an empty result" do
      assert backup() =~ "No meta/latest",
             "a bucket with no pointer would read as nothing to verify"

      refute backup() =~ ~r/No meta\/latest[^\n]*\n\s*exit 0/,
             "a missing pointer must not exit 0"
    end

    test "the pointer is read, not a sorted listing" do
      # meta/latest is written last by the producer, after the object it names
      # is confirmed present. Sorting a listing would find a half-written
      # upload and call it the newest backup.
      assert backup() =~ "meta/latest"

      refute backup() =~ ~r/s3 ls .*\|\s*(sort|tail)/,
             "picking the newest by listing can select a partial upload"
    end
  end

  describe "the dump is restored, not inspected" do
    test "a real postgres restores it every run" do
      # pg_restore --list reads the archive header. It says nothing about
      # whether the data restores, which is the only question that matters.
      assert backup() =~ "pg_restore --no-owner --no-acl",
             "nothing actually restores the dump"

      assert backup() =~ "psql -U postgres -d restored",
             "nothing connects to the restored database"

      # The templated form, which is unique to the per-table loop. Matching
      # "SELECT count(*) FROM public." alone passed with the loop's query
      # replaced by "SELECT 1", because the schema_migrations count below
      # satisfied it -- the guard verified the wrong line.
      assert backup() =~ ~s[SELECT count(*) FROM public.${t}],
             "the per-table row counts are gone, so nothing queries what restored"
    end

    test "an empty restore fails" do
      # Every other check in the file passes for a dump of nothing.
      assert backup() =~ "schema_migrations restored empty",
             "a dump describing no migrated database would verify clean"

      assert backup() =~ ~r/"\$\{MIGRATIONS:-0\}" -lt 1/,
             "the migration count is printed but not checked"
    end

    test "restore errors are not swallowed" do
      # pg_restore is run with `|| true` because no-owner restores emit
      # warnings; the errors then have to be read back out deliberately.
      assert backup() =~ ~r/grep -qi "error" restore\.err/,
             "pg_restore's errors are discarded along with its exit status"
    end
  end

  describe "the producer refuses to report a backup that is not one" do
    test "it checks the object landed rather than trusting the upload" do
      assert producer() =~ "head-object",
             "an upload's exit status is not the object being in the bucket"

      assert producer() =~ "but the bucket does not have it",
             "a missing object after upload does not fail"
    end

    test "meta/latest is written after the object is confirmed" do
      # Order is the whole point: a pointer written first names an object that
      # may never arrive, and every reader would trust it.
      src = producer()
      assert String.contains?(src, "head-object")
      head = :binary.match(src, "head-object") |> elem(0)
      latest = :binary.match(src, "meta/latest") |> elem(0)

      assert head < latest,
             "meta/latest is written before the object it names is confirmed present"
    end

    test "an empty or unreadable dump is not uploaded" do
      assert producer() =~ ~r/"\$SIZE" -ge 10240/, "no size floor on the dump"
      assert producer() =~ "pg_restore --list", "the dump is uploaded without being read back"

      assert producer() =~ "does not decrypt with the passphrase that encrypted it",
             "the artifact is uploaded without a decryption round-trip"
    end

    test "it does not retry itself into a green run" do
      # Documented rather than scripted. The setup script this asserted against
      # was deleted after it failed three times and hung on a prompt that needed
      # kill -9; the flag still has to be written down where the person creating
      # the machine will read it.
      readme = File.read!(Path.join(@root, "ops/backup/README.md"))

      assert readme =~ "--restart no",
             "a restarting machine converts a failure into a success nobody examines"

      refute producer() =~ ~r/for attempt in|until pg_dump|retry/,
             "the producer retries, which turns a diagnosable failure into a quiet one"
    end
  end

  describe "a copy exists outside Fly" do
    test "the verified artifact is kept off Fly on every green run" do
      # Tigris is provisioned through Fly and lives in the same organisation as
      # the database. Without this the nightly copy shares a fate with the
      # volume snapshots it exists to cover for.
      assert backup() =~ "actions/upload-artifact",
             "nothing keeps a copy outside Fly"

      assert backup() =~ "retention-days: 90"
    end

    test "the puller decrypts with the operator's copy, not the CI secret" do
      # CI decrypting with the CI secret proves CI agrees with itself. A
      # password-manager copy that has drifted is undetectable from here.
      assert puller() =~ "BACKUP_PASSCODE",
             "the puller uses the CI secret, so it proves nothing new"

      refute puller() =~ "BACKUP_PASSPHRASE",
             "the puller reads the CI secret's name, which defeats its purpose"

      assert puller() =~ "has drifted from what the producer encrypts with",
             "a passphrase mismatch is not explained as the failure it is"
    end

    test "how long since a copy left Fly is surfaced" do
      assert backup() =~ "meta/last-local-pull",
             "nothing records or reads when a copy was last taken off Fly"

      assert backup() =~ ~r/"\$DAYS" -gt 30/,
             "the gap is printed but never judged"
    end
  end

  describe "secrets stay where they belong" do
    test "CI cannot take a backup or reach the database" do
      src = backup()

      refute src =~ "PG_DUMP_URL",
             "the verification job holds the database credentials it no longer needs"

      refute src =~ "FLY_DB_TOKEN",
             "the verification job can still reach Fly"

      # The header names the proxy as history deliberately, so this asserts it
      # is not *invoked* rather than not mentioned.
      refute src =~ ~r/^\s*flyctl proxy/m,
             "the proxy is still in the nightly path"

      refute src =~ ~r/^\s*pg_dump/m,
             "the verification job still takes the dump it is meant to verify"
    end

    test "CI's bucket credentials are read-only by name" do
      # Naming does not enforce scope -- the scope is set in Tigris. But a
      # read-only name is what makes a write-scoped key here obvious in review.
      assert backup() =~ "TIGRIS_READ_ACCESS_KEY_ID"

      refute backup() =~ ~r/aws[^\n]*s3 (cp|mv) [^\n]*\s+s3:\/\//,
             "the verification job writes to the bucket"
    end

    test "no secret is passed as a command argument" do
      # Both scripts hand passphrases to gpg through a file and tokens to curl
      # through stdin, so neither appears in a process list or a log.
      for {name, src} <- [{"producer", producer()}, {"puller", puller()}] do
        refute src =~ ~r/--passphrase\s+["$]/,
               "#{name} passes the passphrase as an argument; use --passphrase-file"

        assert src =~ "--passphrase-file", "#{name} does not use --passphrase-file"
      end
    end
  end

  test "the files this test reads all exist" do
    # Every assertion above is a string match against a file. A renamed or
    # deleted file would make File.read! raise rather than pass vacuously,
    # which is the behaviour we want -- this asserts the set deliberately.
    for path <- [
          "ops/backup/backup.sh",
          "ops/backup/Dockerfile",
          "ops/backup/fly.toml",
          "ops/backup/README.md",
          "scripts/backup-pull.sh",
          ".github/workflows/backup.yml",
          "docs/adr/006-backup-near-the-data.md"
        ] do
      assert File.exists?(Path.join(@root, path)), "#{path} is missing"
    end
  end
end
