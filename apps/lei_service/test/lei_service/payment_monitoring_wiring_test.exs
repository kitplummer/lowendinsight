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
  defp step(name, step_name),
    do: name |> workflow() |> String.split("- name: #{step_name}") |> List.last()

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

    test "the paging workflows check out the repository that holds the script" do
      for name <- ~w(deploy.yml backup.yml) do
        assert workflow(name) =~ "actions/checkout",
               "#{name} calls scripts/notify.sh without checking the repository out"
      end
    end
  end
end
