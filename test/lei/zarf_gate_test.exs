# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.ZarfGateTest do
  use ExUnit.Case, async: true

  @single_critical %{
    header: %{
      repo: "https://github.com/example/abandoned-lib",
      start_time: "2026-01-01T00:00:00Z",
      end_time: "2026-01-01T00:00:05Z",
      duration: 5,
      uuid: "test-uuid-1",
      source_client: "test",
      library_version: "0.9.0"
    },
    data: %{
      repo: "https://github.com/example/abandoned-lib",
      git: %{hash: "abc123", default_branch: "main"},
      risk: "critical",
      results: %{
        contributor_count: 1,
        contributor_risk: "critical",
        commit_currency_weeks: 200,
        commit_currency_risk: "critical",
        functional_contributors_risk: "critical",
        functional_contributors: 1,
        large_recent_commit_risk: "low",
        sbom_risk: "medium"
      }
    }
  }

  @single_low %{
    header: %{
      repo: "https://github.com/example/healthy-lib",
      start_time: "2026-01-01T00:00:00Z",
      end_time: "2026-01-01T00:00:03Z",
      duration: 3,
      uuid: "test-uuid-2",
      source_client: "test",
      library_version: "0.9.0"
    },
    data: %{
      repo: "https://github.com/example/healthy-lib",
      git: %{hash: "def456", default_branch: "main"},
      risk: "low",
      results: %{
        contributor_count: 25,
        contributor_risk: "low",
        commit_currency_weeks: 1,
        commit_currency_risk: "low",
        functional_contributors_risk: "low",
        functional_contributors: 10,
        large_recent_commit_risk: "low",
        sbom_risk: "low"
      }
    }
  }

  @multi_mixed %{
    state: "complete",
    report: %{
      uuid: "multi-uuid-1",
      repos: [
        %{
          header: %{repo: "https://github.com/example/healthy-lib", uuid: "r1"},
          data: %{
            repo: "https://github.com/example/healthy-lib",
            git: %{hash: "aaa"},
            risk: "low",
            results: %{
              contributor_count: 20,
              contributor_risk: "low",
              commit_currency_risk: "low",
              functional_contributors_risk: "low",
              large_recent_commit_risk: "low",
              sbom_risk: "low"
            }
          }
        },
        %{
          header: %{repo: "https://github.com/example/risky-lib", uuid: "r2"},
          data: %{
            repo: "https://github.com/example/risky-lib",
            git: %{hash: "bbb"},
            risk: "critical",
            results: %{
              contributor_count: 1,
              contributor_risk: "critical",
              commit_currency_risk: "critical",
              functional_contributors_risk: "critical",
              large_recent_commit_risk: "low",
              sbom_risk: "medium"
            }
          }
        }
      ]
    },
    metadata: %{
      repo_count: 2,
      times: %{start_time: "2026-01-01T00:00:00Z"}
    }
  }

  @multi_all_low %{
    state: "complete",
    report: %{
      uuid: "multi-uuid-2",
      repos: [
        %{
          header: %{repo: "https://github.com/example/lib-a", uuid: "r3"},
          data: %{
            repo: "https://github.com/example/lib-a",
            git: %{hash: "ccc"},
            risk: "low",
            results: %{contributor_risk: "low", commit_currency_risk: "low"}
          }
        },
        %{
          header: %{repo: "https://github.com/example/lib-b", uuid: "r4"},
          data: %{
            repo: "https://github.com/example/lib-b",
            git: %{hash: "ddd"},
            risk: "medium",
            results: %{contributor_risk: "medium", commit_currency_risk: "low"}
          }
        }
      ]
    },
    metadata: %{repo_count: 2}
  }

  # --- Threshold evaluation tests ---

  test "single critical repo fails high threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_critical, "high")
    refute result.pass
    assert result.summary.failing == 1
    assert result.summary.total == 1
    assert result.threshold == "high"
  end

  test "single low-risk repo passes high threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "high")
    assert result.pass
    assert result.summary.passing == 1
    assert result.summary.failing == 0
  end

  test "single critical repo passes critical threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_critical, "critical")
    refute result.pass
    assert result.summary.failing == 1
  end

  test "single low repo fails low threshold" do
    # "low" threshold = fail on anything at or above low (i.e. everything)
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "low")
    refute result.pass
  end

  test "single low repo passes medium threshold" do
    # "low" risk does NOT exceed "medium" threshold
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "medium")
    assert result.pass
  end

  # --- Multi-repo evaluation tests ---

  test "multi-repo with mixed risk fails high threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@multi_mixed, "high")
    refute result.pass
    assert result.summary.total == 2
    assert result.summary.passing == 1
    assert result.summary.failing == 1

    [failing] = result.failing_repos
    assert failing.repo == "https://github.com/example/risky-lib"
    assert failing.risk == "critical"
  end

  test "multi-repo all low passes high threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@multi_all_low, "high")
    assert result.pass
    assert result.summary.total == 2
    assert result.summary.failing == 0
  end

  test "multi-repo medium risk fails at medium threshold" do
    {:ok, result} = Lei.ZarfGate.evaluate(@multi_all_low, "medium")
    refute result.pass
    assert result.summary.failing == 1
  end

  # --- Threshold normalization tests ---

  test "invalid threshold defaults to high" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "bogus")
    assert result.threshold == "high"
  end

  test "threshold is case-insensitive" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "HIGH")
    assert result.threshold == "high"
  end

  # --- exceeds_threshold? tests ---

  test "exceeds_threshold? correctly compares risk levels" do
    assert Lei.ZarfGate.exceeds_threshold?("critical", "high")
    assert Lei.ZarfGate.exceeds_threshold?("high", "high")
    refute Lei.ZarfGate.exceeds_threshold?("medium", "high")
    refute Lei.ZarfGate.exceeds_threshold?("low", "high")

    assert Lei.ZarfGate.exceeds_threshold?("critical", "medium")
    assert Lei.ZarfGate.exceeds_threshold?("high", "medium")
    assert Lei.ZarfGate.exceeds_threshold?("medium", "medium")
    refute Lei.ZarfGate.exceeds_threshold?("low", "medium")
  end

  # --- JSON output tests ---

  test "to_json produces valid JSON with gate structure" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_critical, "high")
    {:ok, json} = Lei.ZarfGate.to_json(result)

    decoded = Poison.decode!(json)
    gate = decoded["lei-zarf-gate"]

    assert gate["version"] == "0.1.0"
    assert gate["pass"] == false
    assert gate["threshold"] == "high"
    assert gate["summary"]["total_dependencies"] == 1
    assert gate["summary"]["failing"] == 1
    assert length(gate["failing_dependencies"]) == 1

    [dep] = gate["failing_dependencies"]
    assert dep["repo"] == "https://github.com/example/abandoned-lib"
    assert dep["risk"] == "critical"
  end

  test "to_json for passing result has empty failing list" do
    {:ok, result} = Lei.ZarfGate.evaluate(@single_low, "high")
    {:ok, json} = Lei.ZarfGate.to_json(result)

    decoded = Poison.decode!(json)
    gate = decoded["lei-zarf-gate"]

    assert gate["pass"] == true
    assert gate["failing_dependencies"] == []
  end

  # --- Error handling ---

  test "evaluate returns error for bad input" do
    assert {:error, _} = Lei.ZarfGate.evaluate(%{bad: "data"})
  end
end
