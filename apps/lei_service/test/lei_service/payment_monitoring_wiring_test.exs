defmodule LeiService.PaymentMonitoringWiringTest do
  @moduledoc """
  The payment signals are read by something, and a failure reaches a person.

  Stage F (#139) built the counters over two days -- refunds and disputes
  reaching the ledger (#208), outcomes by rail (#213), a per-rail kill switch
  (#215), reconciliation against Stripe (#216) -- and `monitor.yml` read none
  of them. The gauges were correct and published, and the only thing that
  would have noticed a discrepancy was someone running `scripts/payments.sh`
  by hand. `scripts/notify.sh` had the same shape: a working notifier wired
  into nothing but its own manual test workflow.

  These assertions are deliberately about the workflow files rather than about
  Elixir. A metric nothing reads and an alert nobody receives are both the
  failure this repository keeps meeting, and neither is visible from the
  application's own tests -- `Lei.Metrics` emits the gauge either way.

  `scripts/mutations.json` carries the negative control: removing any check
  below must fail this file.
  """
  use ExUnit.Case, async: true

  defp workflow(name),
    do: File.read!(Path.expand("../../../../.github/workflows/#{name}", __DIR__))

  defp monitor, do: workflow("monitor.yml")

  # Scoped to one step, not to the file.
  #
  # The first version of the deploy assertion checked that `deploy.yml`
  # contained "if: failure()" anywhere, and passed when the mutation disabled
  # the paging step -- the rollback step above it carries its own
  # `if: failure() && ...`. A condition satisfied somewhere else in the file is
  # not the condition on this step.
  # Fails loudly when the step is absent.
  #
  # The first version returned List.last of a split on a marker that was not
  # there -- which is the whole file, so every assertion about the step matched
  # against unrelated content elsewhere in the workflow and passed. A test that
  # cannot find its subject must say so, not quietly widen its search.
  defp step(name, step_name) do
    marker = "- name: #{step_name}"
    source = workflow(name)

    assert String.contains?(source, marker),
           "#{name} has no step named #{inspect(step_name)}"

    source |> String.split(marker) |> List.last()
  end

  describe "the monitor reads the money" do
    test "it fails when the ledger and Stripe disagree" do
      assert monitor() =~ ~s(lei_stripe_reconciliation{measure="discrepancies"})

      assert monitor() =~ ~r/DISCREPANCIES:-0\}" -gt 0/,
             "a discrepancy count is read but never compared"
    end

    test "a reconciliation that stopped running is a failure, not a stale pass" do
      assert monitor() =~ ~s(lei_stripe_reconciliation{measure="age_seconds"})
      assert monitor() =~ "10800"
    end

    test "a reconciliation that could not be computed does not read as clean" do
      assert monitor() =~ ~s(lei_stripe_reconciliation{measure="error"})
      assert monitor() =~ ~s(lei_stripe_reconciliation{measure="failed"})
    end

    test "absent reconciliation metrics fail rather than pass" do
      assert monitor() =~ "No Stripe reconciliation metrics"

      refute monitor() =~ ~r/No Stripe reconciliation metrics.*\n.*exit 0/,
             "a missing comparison must not exit 0"
    end

    # Asserting the text alone is not enough: the first version of this test
    # matched "switched off" and passed happily when the mutation downgraded
    # the line from ::error:: to ::notice::, which fails nothing. The severity
    # is the check.
    test "it fails on a rail left switched off" do
      assert monitor() =~ "lei_payment_switch_enabled"
      assert monitor() =~ "::error::Payment path(s) switched off"
    end

    # Naming the gauge is not enough: it is named twice in this file, once in
    # the family-presence loop above, so a mutation that hardcoded HELD=0 left
    # both mentions standing and the assertion passed. The count has to be
    # read out of the response.
    test "it fails on a credential held after a refusal" do
      assert monitor() =~ "HELD=$(echo \"$METRICS\" | grep '^lei_payment_held{'"
      assert monitor() =~ "::error::${HELD} payment credential"
    end

    test "it fails on a refund or dispute that matched no purchase" do
      assert monitor() =~ ~s(lei_stripe_reversal_events_total{result="unmatched"})
      assert monitor() =~ "matched no credit purchase"
    end

    # The first version of this step had the bug it was written to catch.
    # Every check read its number with grep, and grep finding nothing is the
    # same empty string as a rail reporting zero -- so a collector that
    # stopped being registered would have turned the whole step green.
    test "a payment gauge family that vanished fails rather than reading as zero" do
      assert monitor() =~ "::error::/metrics is not publishing ${family}"

      for family <- ~w(lei_payment_switch_enabled lei_payment_held
                       lei_stripe_reversal_events_total lei_payment_outcomes) do
        assert monitor() =~ family
      end
    end

    test "conversion is reported but never judged" do
      assert monitor() =~ "lei_payment_outcomes"

      refute monitor() =~ ~r/lei_payment_outcomes.*\n.*::error::/,
             "settlement counts are noisy in sandbox; a threshold here would be alert fatigue"
    end
  end

  describe "a check that cannot do its job fails" do
    test "the smoke step fails when its key is absent, rather than warning" do
      smoke =
        monitor()
        |> String.split("- name: Smoke test against production")
        |> List.last()

      assert smoke =~ "LEI_SMOKE_API_KEY is not set"
      assert smoke =~ "::error::"

      refute smoke =~ "::warning::LEI_SMOKE_API_KEY",
             "warning-and-exit-0 is how this step reported success while running nothing"
    end
  end

  describe "a failure reaches a person" do
    test "a failed deploy pages" do
      page = step("deploy.yml", "Page on a failed deploy")

      assert page =~ "if: failure()"
      assert page =~ "scripts/notify.sh"
      assert page =~ "--priority 5"
    end

    test "a failed backup pages" do
      page = step("backup.yml", "Page on a failed backup")

      assert page =~ "if: failure()"
      assert page =~ "scripts/notify.sh"
    end

    # The monitor was deliberately left off paging when #225 shipped: its smoke
    # step was going to be red until LEI_SMOKE_API_KEY existed, and a page every
    # fifteen minutes is how an alarm stops being read. The key is set now.
    test "a failing monitor pages" do
      page = step("monitor.yml", "Page on a failed check")

      assert page =~ "if: failure()"
      assert page =~ "scripts/notify.sh"
    end

    # It runs every 15 minutes. Paging on every run of an outage is 96 pages a
    # day for one incident, which is worse than the email it replaces -- the
    # operator stops reading, which is the failure this whole file is about.
    # So it pages on the transition into failure, not on the state.
    test "it pages once per incident, not once per run" do
      page = step("monitor.yml", "Page on a failed check")

      # Pins the comparison, not the vocabulary. Asserting that the word
      # "previous" appears passed happily when the mutation compared it
      # against a value nothing can equal.
      assert page =~ ~s(if [ "$PREVIOUS" = "failure" ]; then),
             "the page is not gated on the previous run having failed"

      assert page =~ "exit 0", "a known incident must exit quietly, not page"

      assert page =~ ~r/github\.run_id/,
             "the previous run cannot be identified without excluding this one"
    end

    # A page suppressed because we could not tell whether the last run failed
    # is a page that did not happen. Unknown means send it.
    test "it pages when the previous run's state cannot be determined" do
      page = step("monitor.yml", "Page on a failed check")

      # The default matters, not the word: "unknown" also appears in the echo
      # and the comments, so matching it anywhere proved nothing.
      assert page =~ ~s(PREVIOUS="${PREVIOUS:-unknown}"),
             "an empty lookup result must not default to anything that suppresses the page"
    end

    test "the page names what actually failed" do
      monitor = monitor()

      # Step ids, so the page can say which check broke rather than "something".
      for id <- ~w(alerting readiness queue webhooks ledger payments canary smoke) do
        assert monitor =~ "id: #{id}",
               "step '#{id}' has no id, so the page cannot name it"
      end
    end

    # ntfy rejected the backup page with a 401 on 2026-09-23 and again on
    # 2026-09-24. The backup had genuinely failed both nights, notify.sh
    # correctly exited non-zero, and the page still reached nobody. Nothing
    # checked the channel on a schedule: it was proved once by hand on
    # 2026-09-17 and assumed to hold. An alarm that cannot ring is the shape
    # this repository keeps meeting, one layer further out again.
    test "the monitor checks it can still page before checking anything else" do
      probe = step("monitor.yml", "Check the alert channel")

      assert probe =~ "NTFY_TOKEN", "the probe does not use the paging credential"

      # The topic's auth endpoint, which answers whether this token may
      # publish here -- without sending a notification every 15 minutes.
      assert probe =~ "/auth", "the probe does not ask ntfy whether the token is accepted"

      # The status has to be compared. A probe that records a code and never
      # reads it is the check that passes while it cannot do its job.
      assert probe =~ ~r/2\?\?\)/,
             "the probe never distinguishes an accepted credential from a rejected one"

      assert probe =~ "::error::", "a rejected credential does not fail the run"

      # The page has to be able to name this check, or a dead alert channel
      # reads as "unidentified" -- something is wrong, and not what.
      assert monitor() =~ "ALERTING: ${{ steps.alerting.outcome }}",
             "the alert-channel check is not collected for the page"

      assert monitor() =~ ~s("alerting:$ALERTING"),
             "the alert-channel check is not named in the failure list"
    end

    test "an alert channel it could not reach is not a working one" do
      probe = step("monitor.yml", "Check the alert channel")

      # 401 is the case seen; a 5xx or no response at all leaves the same
      # question unanswered, and the rest of this file treats an answer it
      # could not get as a failure.
      refute probe =~ ~r/\*\)\s*\n\s*(echo[^\n]*\n\s*)?exit 0/,
             "an unanswered probe exits 0, which reports a channel nobody has tested as working"

      # The step runs under `bash -e`. A connection curl could not make exits
      # 7, which aborts the step before the branch above has said why -- the
      # run fails, and pages as "unidentified" rather than naming ntfy.
      assert probe =~ ~r/auth" \|\| true\)/,
             "a failed connection aborts the step before it can say what went wrong"
    end

    test "the paging workflows check out the repository that holds the script" do
      for name <- ~w(deploy.yml backup.yml monitor.yml) do
        assert workflow(name) =~ "actions/checkout",
               "#{name} calls scripts/notify.sh without checking the repository out"
      end
    end
  end
end
