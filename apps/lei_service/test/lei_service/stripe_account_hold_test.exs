defmodule LeiService.StripeAccountHoldTest do
  @moduledoc """
  A Stripe account hold, made visible.

  The runbook for a hold (`OPERATIONS.md`, "Stripe places the account on
  hold") was written on 2026-09-20 with a known gap: nothing read account
  state. A held account answers every read `/readyz` makes, so a hold was
  invisible to every check -- and paused payouts show nowhere at all: money
  keeps arriving, the ledger reconciles, and none of it reaches the bank.

  Two halves, both tested by execution: the gauges `/metrics` publishes, and
  `scripts/check-stripe-account.sh`, which reads them the way the monitor will.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/check-stripe-account.sh", __DIR__)

  defp account(result, charges, payouts, reason \\ nil),
    do: %{
      result: result,
      charges_enabled: charges,
      payouts_enabled: payouts,
      disabled_reason: reason
    }

  describe "the gauges" do
    test "an account read publishes both flags and the read's result" do
      lines = Lei.Metrics.stripe_account_metrics(account("ok", true, false))

      assert ~s(lei_stripe_account{measure="check",result="ok"} 1) in lines
      assert ~s(lei_stripe_account{measure="charges_enabled"} 1) in lines
      assert ~s(lei_stripe_account{measure="payouts_enabled"} 0) in lines
    end

    test "an account that could not be read publishes no flags" do
      # A flag published as 0 or 1 when nothing was read would be a guess: 1 is
      # an all-clear nobody gave, and 0 is a hold nobody placed.
      lines = Lei.Metrics.stripe_account_metrics(account("unreachable", nil, nil))

      assert ~s(lei_stripe_account{measure="check",result="unreachable"} 1) in lines
      refute Enum.any?(lines, &(&1 =~ "charges_enabled"))
      refute Enum.any?(lines, &(&1 =~ "payouts_enabled"))
    end

    test "Stripe's reason is published, and cannot break the exposition format" do
      lines =
        Lei.Metrics.stripe_account_metrics(
          account("ok", false, false, ~s(requirements.past_due"} 1\nevil 1))
        )

      reason = Enum.find(lines, &(&1 =~ ~s(measure="disabled")))
      assert reason =~ ~r/^lei_stripe_account\{measure="disabled",reason="[a-z0-9_.]+"\} 1$/
    end

    test "the collector publishes the family" do
      assert Lei.Metrics.collect() =~ ~s(lei_stripe_account{measure="check",result=")
    end
  end

  describe "scripts/check-stripe-account.sh" do
    defp metrics(mode, lines),
      do: Enum.join([~s(lei_stripe_mode{mode="#{mode}"} 1) | lines], "\n") <> "\n"

    defp run(input) do
      path = Path.join(System.tmp_dir!(), "stripe-account-#{System.unique_integer([:positive])}")
      File.write!(path, input)

      try do
        System.cmd("bash", ["-c", ~s("$0" < "$1"), @script, path], stderr_to_stdout: true)
      after
        File.rm(path)
      end
    end

    defp healthy,
      do: [
        ~s(lei_stripe_account{measure="check",result="ok"} 1),
        ~s(lei_stripe_account{measure="charges_enabled"} 1),
        ~s(lei_stripe_account{measure="payouts_enabled"} 1)
      ]

    test "live, and the account can charge and pay out: passes" do
      assert {_, 0} = run(metrics("live", healthy()))
    end

    test "live, charges disabled: fails, naming the runbook" do
      {out, status} =
        run(
          metrics("live", [
            ~s(lei_stripe_account{measure="check",result="ok"} 1),
            ~s(lei_stripe_account{measure="charges_enabled"} 0),
            ~s(lei_stripe_account{measure="payouts_enabled"} 0),
            ~s(lei_stripe_account{measure="disabled",reason="requirements.past_due"} 1)
          ])
        )

      assert status == 1
      # Payouts are paused here too, and that error names the same runbook, so
      # the charges error is asserted by its own words.
      assert out =~ "::error::The Stripe account cannot take charges"
      assert out =~ "Stripe places the account on hold"
      assert out =~ "requirements.past_due"
    end

    test "live, only payouts paused: fails -- the hold nothing else sees" do
      {out, status} =
        run(
          metrics("live", [
            ~s(lei_stripe_account{measure="check",result="ok"} 1),
            ~s(lei_stripe_account{measure="charges_enabled"} 1),
            ~s(lei_stripe_account{measure="payouts_enabled"} 0)
          ])
        )

      assert status == 1
      assert out =~ "::error::Stripe payouts are paused"
      refute out =~ "cannot take charges", "charges work here; only payouts are paused"
    end

    test "live, the account could not be read: fails rather than passing on silence" do
      {out, status} =
        run(metrics("live", [~s(lei_stripe_account{measure="check",result="unauthorized"} 1)]))

      assert status == 1
      # The summary line prints the result whatever happens, so the error
      # itself is what is asserted.
      assert out =~ "::error::The Stripe account could not be read (unauthorized)"
    end

    test "live, a flag missing although the read succeeded: fails" do
      {_, status} =
        run(
          metrics("live", [
            ~s(lei_stripe_account{measure="check",result="ok"} 1),
            ~s(lei_stripe_account{measure="charges_enabled"} 1)
          ])
        )

      assert status == 1
    end

    test "test mode is enforced too" do
      # Production's sandbox account reports both flags true (observed after
      # #365 deployed), so enforcing before cutover costs no false pages -- and
      # a hold on the account would otherwise go unseen until the live key went
      # in.
      {out, status} =
        run(
          metrics("test", [
            ~s(lei_stripe_account{measure="check",result="ok"} 1),
            ~s(lei_stripe_account{measure="charges_enabled"} 0),
            ~s(lei_stripe_account{measure="payouts_enabled"} 1)
          ])
        )

      assert status == 1, "a hold in test mode passed"
      assert out =~ "::error::The Stripe account cannot take charges"
    end

    test "test mode, an unread account fails too" do
      {_, status} =
        run(metrics("test", [~s(lei_stripe_account{measure="check",result="unauthorized"} 1)]))

      assert status == 1
    end

    test "test mode, a healthy account passes" do
      assert {_, 0} = run(metrics("test", healthy()))
    end

    test "the family absent fails in any mode: an absent check reads exactly like a clean one" do
      for mode <- ["test", "live"] do
        {out, status} = run(metrics(mode, []))
        assert status == 1, "#{mode}: passed with no account metrics at all"
        assert out =~ "lei_stripe_account"
      end
    end

    test "empty input fails" do
      assert {_, 1} = run("")
    end
  end
end
