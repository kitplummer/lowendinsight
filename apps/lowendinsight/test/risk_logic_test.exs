# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule RiskLogicTest do
  use ExUnit.Case, async: false
  doctest RiskLogic

  test "confirm sbom risk medium" do
    assert RiskLogic.sbom_risk() == {:ok, "medium"}
  end

  test "confirm contributor critical" do
    assert RiskLogic.contributor_risk(1) == {:ok, "critical"}
  end

  test "confirm contributor high" do
    assert RiskLogic.contributor_risk(2) == {:ok, "high"}
  end

  test "confirm contributor medium" do
    assert RiskLogic.contributor_risk(4) == {:ok, "medium"}
  end

  test "confirm contributor low" do
    assert RiskLogic.contributor_risk(5) == {:ok, "low"}
  end

  test "confirm currency critical" do
    assert RiskLogic.commit_currency_risk(104) == {:ok, "critical"}
  end

  test "confirm currency more than critical" do
    assert RiskLogic.commit_currency_risk(105) == {:ok, "critical"}
  end

  test "confirm currency high" do
    assert RiskLogic.commit_currency_risk(52) == {:ok, "high"}
  end

  test "confirm currency more than high" do
    assert RiskLogic.commit_currency_risk(53) == {:ok, "high"}
  end

  test "confirm currency medium" do
    assert RiskLogic.commit_currency_risk(26) == {:ok, "medium"}
  end

  test "confirm currency more than medium" do
    assert RiskLogic.commit_currency_risk(27) == {:ok, "medium"}
  end

  test "confirm currency low" do
    assert RiskLogic.commit_currency_risk(25) == {:ok, "low"}
  end

  test "confirm large commit low" do
    assert RiskLogic.commit_change_size_risk(0.04) == {:ok, "low"}
  end

  test "confirm large commit medium" do
    assert RiskLogic.commit_change_size_risk(0.20) == {:ok, "medium"}
  end

  test "confirm large commit high" do
    assert RiskLogic.commit_change_size_risk(0.16) == {:ok, "low"}
  end

  test "confirm large commit critical" do
    assert RiskLogic.commit_change_size_risk(0.45) == {:ok, "critical"}
  end

  test "confirm functional commiters low" do
    assert RiskLogic.functional_contributors_risk(6) == {:ok, "low"}
    assert RiskLogic.functional_contributors_risk(5) == {:ok, "low"}
  end

  test "confirm functional commiters medium" do
    assert RiskLogic.functional_contributors_risk(4) == {:ok, "medium"}
    assert RiskLogic.functional_contributors_risk(3) == {:ok, "medium"}
  end

  test "confirm functional commiters high" do
    assert RiskLogic.functional_contributors_risk(2) == {:ok, "high"}
  end

  test "confirm functional commiters critical" do
    assert RiskLogic.functional_contributors_risk(1) == {:ok, "critical"}
  end

  test "confirm functional commiters zero" do
    assert RiskLogic.functional_contributors_risk(0) == {:ok, "critical"}
  end

  test "confirm large commit high at 35%" do
    assert RiskLogic.commit_change_size_risk(0.35) == {:ok, "high"}
  end

  test "confirm large commit critical at threshold" do
    assert RiskLogic.commit_change_size_risk(0.50) == {:ok, "critical"}
  end

  test "confirm currency at exact thresholds" do
    # At medium threshold
    assert RiskLogic.commit_currency_risk(26) == {:ok, "medium"}
    # Just below medium
    assert RiskLogic.commit_currency_risk(25) == {:ok, "low"}
    # At high threshold
    assert RiskLogic.commit_currency_risk(52) == {:ok, "high"}
    # At critical threshold
    assert RiskLogic.commit_currency_risk(104) == {:ok, "critical"}
  end

  test "confirm contributor at exact thresholds" do
    # At critical threshold
    assert RiskLogic.contributor_risk(2) == {:ok, "high"}
    # At high threshold
    assert RiskLogic.contributor_risk(3) == {:ok, "medium"}
    # At medium threshold
    assert RiskLogic.contributor_risk(5) == {:ok, "low"}
    # Above medium
    assert RiskLogic.contributor_risk(10) == {:ok, "low"}
  end

  test "confirm contributor risk with zero contributors" do
    assert RiskLogic.contributor_risk(0) == {:ok, "critical"}
  end

  test "confirm commit_change_size_risk at exact medium threshold" do
    assert RiskLogic.commit_change_size_risk(0.20) == {:ok, "medium"}
  end

  test "confirm commit_change_size_risk just below medium" do
    assert RiskLogic.commit_change_size_risk(0.19) == {:ok, "low"}
  end

  test "confirm commit_change_size_risk at exact high threshold" do
    assert RiskLogic.commit_change_size_risk(0.30) == {:ok, "high"}
  end

  test "confirm commit_change_size_risk at exact critical threshold" do
    assert RiskLogic.commit_change_size_risk(0.40) == {:ok, "critical"}
  end

  test "confirm commit_change_size_risk above critical" do
    assert RiskLogic.commit_change_size_risk(0.99) == {:ok, "critical"}
  end

  test "confirm currency risk at zero weeks" do
    assert RiskLogic.commit_currency_risk(0) == {:ok, "low"}
  end

  test "confirm currency risk at very high weeks" do
    assert RiskLogic.commit_currency_risk(1000) == {:ok, "critical"}
  end

  test "confirm functional_contributors_risk at exact medium threshold" do
    assert RiskLogic.functional_contributors_risk(5) == {:ok, "low"}
  end

  test "confirm functional_contributors_risk at exact high threshold" do
    assert RiskLogic.functional_contributors_risk(3) == {:ok, "medium"}
  end

  test "confirm functional_contributors_risk at exact critical threshold" do
    assert RiskLogic.functional_contributors_risk(2) == {:ok, "high"}
  end

  test "confirm functional_contributors_risk below critical" do
    assert RiskLogic.functional_contributors_risk(1) == {:ok, "critical"}
  end

  test "contributor_risk with large number" do
    assert RiskLogic.contributor_risk(100) == {:ok, "low"}
  end

  test "functional_contributors_risk with large number" do
    assert RiskLogic.functional_contributors_risk(100) == {:ok, "low"}
  end

  describe "agentic_classification" do
    test "human when ratio below 0.3" do
      assert RiskLogic.agentic_classification(0.0) == {:ok, "human"}
      assert RiskLogic.agentic_classification(0.29) == {:ok, "human"}
    end

    test "mixed when ratio at or above 0.3 and at or below 0.7" do
      assert RiskLogic.agentic_classification(0.3) == {:ok, "mixed"}
      assert RiskLogic.agentic_classification(0.5) == {:ok, "mixed"}
      assert RiskLogic.agentic_classification(0.7) == {:ok, "mixed"}
    end

    test "agent when ratio above 0.7" do
      assert RiskLogic.agentic_classification(0.71) == {:ok, "agent"}
      assert RiskLogic.agentic_classification(1.0) == {:ok, "agent"}
    end
  end

  describe "config fallback branches" do
    # These tests delete config to exercise the default branches. They used to
    # put it back at the end of each test body, which meant a failed assertion
    # left the keys deleted for everything that ran afterwards -- the same
    # defect that made the rate-limit tests seed-dependent. Snapshot once and
    # restore on exit, so the cleanup survives a failure.
    setup do
      keys = ~w(
        critical_contributor_level
        critical_currency_level
        critical_functional_contributors_level
        critical_large_commit_level
        high_agentic_level
        high_contributor_level
        high_currency_level
        high_functional_contributors_level
        high_large_commit_level
        medium_agentic_level
        medium_contributor_level
        medium_currency_level
        medium_functional_contributors_level
        medium_large_commit_level
      )a

      original = Map.new(keys, &{&1, Application.get_env(:lowendinsight, &1)})

      on_exit(fn ->
        Enum.each(original, fn
          {key, nil} -> Application.delete_env(:lowendinsight, key)
          {key, value} -> Application.put_env(:lowendinsight, key, value)
        end)
      end)

      :ok
    end

    test "contributor_risk uses defaults when config is missing" do
      Application.delete_env(:lowendinsight, :critical_contributor_level)
      Application.delete_env(:lowendinsight, :high_contributor_level)
      Application.delete_env(:lowendinsight, :medium_contributor_level)

      # Defaults: critical=2, high=3, medium=5
      assert RiskLogic.contributor_risk(1) == {:ok, "critical"}
      assert RiskLogic.contributor_risk(2) == {:ok, "high"}
      assert RiskLogic.contributor_risk(4) == {:ok, "medium"}
      assert RiskLogic.contributor_risk(5) == {:ok, "low"}
    end

    test "commit_currency_risk uses defaults when config is missing" do
      Application.delete_env(:lowendinsight, :medium_currency_level)
      Application.delete_env(:lowendinsight, :high_currency_level)
      Application.delete_env(:lowendinsight, :critical_currency_level)

      # Defaults: medium=26, high=52, critical=52
      assert RiskLogic.commit_currency_risk(25) == {:ok, "low"}
      assert RiskLogic.commit_currency_risk(26) == {:ok, "medium"}
      assert RiskLogic.commit_currency_risk(52) == {:ok, "critical"}
    end

    test "commit_change_size_risk uses defaults when config is missing" do
      Application.delete_env(:lowendinsight, :medium_large_commit_level)
      Application.delete_env(:lowendinsight, :high_large_commit_level)
      Application.delete_env(:lowendinsight, :critical_large_commit_level)

      # Defaults: medium=0.2, high=0.3, critical=0.5
      assert RiskLogic.commit_change_size_risk(0.1) == {:ok, "low"}
      assert RiskLogic.commit_change_size_risk(0.25) == {:ok, "medium"}
      assert RiskLogic.commit_change_size_risk(0.35) == {:ok, "high"}
      assert RiskLogic.commit_change_size_risk(0.6) == {:ok, "critical"}
    end

    test "functional_contributors_risk uses defaults when config is missing" do
      Application.delete_env(:lowendinsight, :medium_functional_contributors_level)
      Application.delete_env(:lowendinsight, :high_functional_contributors_level)
      Application.delete_env(:lowendinsight, :critical_functional_contributors_level)

      # Defaults: medium=5, high=5, critical=2
      assert RiskLogic.functional_contributors_risk(5) == {:ok, "low"}
      assert RiskLogic.functional_contributors_risk(2) == {:ok, "high"}
      assert RiskLogic.functional_contributors_risk(1) == {:ok, "critical"}
    end

    test "agentic_classification uses defaults when config is missing" do
      Application.delete_env(:lowendinsight, :high_agentic_level)
      Application.delete_env(:lowendinsight, :medium_agentic_level)

      # Defaults: medium=0.3, high=0.7
      assert RiskLogic.agentic_classification(0.29) == {:ok, "human"}
      assert RiskLogic.agentic_classification(0.3) == {:ok, "mixed"}
      assert RiskLogic.agentic_classification(0.7) == {:ok, "mixed"}
      assert RiskLogic.agentic_classification(0.71) == {:ok, "agent"}
    end
  end
end
