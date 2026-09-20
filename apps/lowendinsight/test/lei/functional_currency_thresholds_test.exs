defmodule Lei.FunctionalCurrencyThresholdsTest do
  @moduledoc """
  Functional commit currency has its own levels, and they move on their own.

  The two currency metrics cannot share thresholds. The last substantive commit
  is always at or before the last commit of any kind, so under one set of
  levels `functional_commit_currency_risk` can only ever be the worse of the
  two -- and because a report's verdict is the maximum across results, the
  plain metric could never be the one that decides. Sharing would also mean
  tuning the metric that governs the verdict silently moved the one that does
  not.

  These tests hold that separation. They are `async: false` because
  application environment is global to the node.
  """
  use ExUnit.Case, async: false

  @functional_keys [
    :medium_functional_currency_level,
    :high_functional_currency_level,
    :critical_functional_currency_level
  ]

  @plain_keys [:medium_currency_level, :high_currency_level, :critical_currency_level]

  setup do
    saved =
      for key <- @functional_keys ++ @plain_keys do
        {key, Application.fetch_env(:lowendinsight, key)}
      end

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:lowendinsight, key, v)
          :error -> Application.delete_env(:lowendinsight, key)
        end
      end
    end)

    :ok
  end

  defp functional(weeks) do
    {:ok, risk} = RiskLogic.functional_commit_currency_risk(weeks)
    risk
  end

  defp plain(weeks) do
    {:ok, risk} = RiskLogic.commit_currency_risk(weeks)
    risk
  end

  describe "the two metrics tune independently" do
    test "tightening functional currency does not move plain currency" do
      before_plain = plain(10)

      Application.put_env(:lowendinsight, :medium_functional_currency_level, 4)
      Application.put_env(:lowendinsight, :high_functional_currency_level, 13)
      Application.put_env(:lowendinsight, :critical_functional_currency_level, 39)

      assert functional(10) == "medium", "the functional levels did not take effect"

      assert plain(10) == before_plain,
             "changing the functional levels moved the plain metric with them"
    end

    test "each functional level is reachable once set" do
      Application.put_env(:lowendinsight, :medium_functional_currency_level, 4)
      Application.put_env(:lowendinsight, :high_functional_currency_level, 13)
      Application.put_env(:lowendinsight, :critical_functional_currency_level, 39)

      assert functional(2) == "low"
      assert functional(6) == "medium"
      assert functional(20) == "high"
      assert functional(52) == "critical"
    end
  end

  describe "with no configuration at all" do
    # `commit_currency_risk/1` falls back to 52 for both its high and critical
    # levels, so a consumer using the library standalone can never be told
    # "high" -- a whole severity silently absent. This metric must not inherit
    # that shape.
    setup do
      for key <- @functional_keys, do: Application.delete_env(:lowendinsight, key)
      :ok
    end

    test "every severity is still reachable" do
      levels =
        [5, 20, 40, 100]
        |> Enum.map(&functional/1)

      assert levels == ["low", "medium", "high", "critical"],
             "a severity is unreachable on the built-in fallbacks: got #{inspect(levels)}"
    end
  end

  describe "the shipped levels" do
    # Pinned so the numbers are a decision with a reason rather than a value
    # nobody would notice changing. 13/26/52 against the plain metric's
    # 26/52/104: this measures something stronger, because a quarter with no
    # human, non-documentation commit is a quarter in which nobody worked on
    # the project, where the plain metric's silence can be broken by a bot.
    test "are 13 / 26 / 52 weeks as configured" do
      assert functional(12) == "low"
      assert functional(13) == "medium"
      assert functional(25) == "medium"
      assert functional(26) == "high"
      assert functional(51) == "high"
      assert functional(52) == "critical"
    end

    test "are tighter than the plain currency levels at every boundary" do
      # The plain metric is informational now; if it were ever the stricter of
      # the two it would start deciding verdicts again, silently.
      for weeks <- [13, 26, 52] do
        severity = fn r -> Enum.find_index(["low", "medium", "high", "critical"], &(&1 == r)) end

        assert severity.(functional(weeks)) >= severity.(plain(weeks)),
               "plain currency is stricter than functional at #{weeks}w"
      end
    end
  end

  describe "the shape that made sharing untenable" do
    test "a substantive age is never younger than the plain age, so it can only score worse" do
      # Not a property of the configuration -- a property of the dates. Under
      # equal thresholds this is what makes the plain metric unable to decide
      # a verdict, which is why it now has levels of its own.
      Application.put_env(:lowendinsight, :medium_functional_currency_level, 26)
      Application.put_env(:lowendinsight, :high_functional_currency_level, 52)
      Application.put_env(:lowendinsight, :critical_functional_currency_level, 104)

      severity = fn risk ->
        Enum.find_index(["low", "medium", "high", "critical"], &(&1 == risk))
      end

      for plain_weeks <- [0, 10, 30, 60, 120] do
        for extra <- [0, 5, 40, 100] do
          substantive_weeks = plain_weeks + extra

          assert severity.(functional(substantive_weeks)) >= severity.(plain(plain_weeks)),
                 "functional #{substantive_weeks}w scored below plain #{plain_weeks}w"
        end
      end
    end
  end
end
