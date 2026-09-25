defmodule Lei.TestHygieneTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Application env is global and outlives the test that set it. Twice now a test
  has overridden :rate_limits and then *deleted* it rather than restoring it,
  leaving the next test file to run against the limiter's hardcoded fallback --
  which made Lei.Acp.RateLimitTest pass or fail depending on the ExUnit seed,
  and shipped a false green both times (#99, and again after it).

  Grepping the suite is a blunt instrument, but the failure it prevents is
  invisible: nothing fails at the point of the mistake, only somewhere else,
  sometimes.
  """

  @test_root Path.expand("..", __DIR__)

  defp test_files do
    Path.wildcard(Path.join(@test_root, "**/*_test.exs"))
  end

  test "a test that overrides application env restores it on exit" do
    offenders =
      for path <- test_files(),
          source = File.read!(path),
          String.contains?(source, "Application.put_env(:lei_service"),
          # on_exit and try/after both survive a failed assertion. Restoring at
          # the end of the test body does not, which is the case being caught.
          not (String.contains?(source, "on_exit") or String.contains?(source, "\n    after\n")),
          do: Path.relative_to(path, @test_root)

    assert offenders == [],
           """
           These test files override application env without an on_exit to put it back:

             #{Enum.join(offenders, "\n  ")}

           Capture the original with Application.get_env/2 and restore it from
           on_exit or a try/after -- both of which still run when an assertion
           fails. Restoring at the end of the test body does not.

           Restore rather than delete: deleting is what makes the next file see
           the limiter's fallback instead of the configured value.
           """
  end

  test "no test deletes :rate_limits outside a restore branch" do
    # The only legitimate delete is the nil arm of a restore: the key genuinely
    # was not set, so putting it back means removing it again.
    offenders =
      for path <- test_files(),
          source = File.read!(path),
          String.contains?(source, "Application.delete_env(:lei_service, :rate_limits)"),
          not String.contains?(
            source,
            "nil -> Application.delete_env(:lei_service, :rate_limits)"
          ),
          do: Path.relative_to(path, @test_root)

    assert offenders == [],
           """
           These test files delete :rate_limits rather than restoring it:

             #{Enum.join(offenders, "\n  ")}

           Lei.RateLimiter falls back to a hardcoded free-tier limit when the key
           is missing, so the damage is silent and lands in a different file.
           """
  end

  test "a test that freezes a clock does not hand the code under test the real one" do
    # A fixture dated from a frozen @now, compared against a window measured
    # from DateTime.utc_now(), is inside the window until real time walks past
    # it. The test then passes for days and starts failing on a date nobody
    # changed anything on. This is how the nightly broke on 2026-09-25: a
    # ledger purchase an hour before a frozen 2026-09-17 fell out of the
    # reconciliation's seven-day window measured from the real clock.
    offenders =
      for path <- test_files(),
          source = File.read!(path),
          String.contains?(source, "@now ~U[") or String.contains?(source, "@now ~N["),
          Regex.match?(~r/now: (DateTime|NaiveDateTime)\.utc_now\(\)/, source),
          do: Path.relative_to(path, @test_root)

    assert offenders == [],
           """
           These test files freeze a clock in @now and also pass the real clock
           as the code's notion of now:

             #{Enum.join(offenders, "\n  ")}

           Pass the frozen @now everywhere. Mixing the two dates the test
           against the calendar: it stays green until the gap between @now and
           today grows past whatever window the code measures, then fails on a
           day with no change behind it.
           """
  end

  test "the hygiene check can actually see the suite" do
    # A wildcard that resolves to nothing would make both checks above pass
    # vacuously -- the same class of bug they exist to catch.
    files = test_files()

    assert length(files) > 20
    assert Enum.any?(files, &String.ends_with?(&1, "rate_limiter_test.exs"))
  end
end
