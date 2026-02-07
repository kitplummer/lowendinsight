# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.ZarfGate.SarifTest do
  use ExUnit.Case, async: true

  @critical_report %{
    header: %{
      repo: "https://github.com/example/abandoned-lib",
      uuid: "test-uuid-1"
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

  test "generates valid SARIF v2.1.0 structure" do
    {:ok, gate_result} = Lei.ZarfGate.evaluate(@critical_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)

    assert sarif["version"] == "2.1.0"
    assert sarif["$schema"] =~ "sarif-schema"
    assert length(sarif["runs"]) == 1

    [run] = sarif["runs"]
    assert run["tool"]["driver"]["name"] == "lei-zarf-gate"
    assert length(run["tool"]["driver"]["rules"]) == 5
  end

  test "SARIF results include overall risk finding" do
    {:ok, gate_result} = Lei.ZarfGate.evaluate(@critical_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    results = run["results"]

    overall = Enum.find(results, &(&1["ruleId"] == "lei/overall-risk"))
    assert overall != nil
    assert overall["level"] == "error"
    assert overall["message"]["text"] =~ "critical"
    assert overall["message"]["text"] =~ "abandoned-lib"
  end

  test "SARIF results include individual risk findings" do
    {:ok, gate_result} = Lei.ZarfGate.evaluate(@critical_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    results = run["results"]

    rule_ids = Enum.map(results, & &1["ruleId"])
    assert "lei/contributor-risk" in rule_ids
    assert "lei/commit-currency-risk" in rule_ids
    assert "lei/functional-contributors-risk" in rule_ids
  end

  test "SARIF maps risk levels to correct SARIF levels" do
    {:ok, gate_result} = Lei.ZarfGate.evaluate(@critical_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    overall = Enum.find(run["results"], &(&1["ruleId"] == "lei/overall-risk"))
    assert overall["level"] == "error"
  end

  test "SARIF has no results for passing gate" do
    passing_report = %{
      header: %{repo: "https://github.com/example/good-lib", uuid: "test-uuid-2"},
      data: %{
        repo: "https://github.com/example/good-lib",
        git: %{hash: "xyz"},
        risk: "low",
        results: %{
          contributor_risk: "low",
          commit_currency_risk: "low",
          functional_contributors_risk: "low",
          large_recent_commit_risk: "low",
          sbom_risk: "low"
        }
      }
    }

    {:ok, gate_result} = Lei.ZarfGate.evaluate(passing_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    assert run["results"] == []
  end

  test "SARIF results have valid location structure" do
    {:ok, gate_result} = Lei.ZarfGate.evaluate(@critical_report, "high")
    {:ok, json} = Lei.ZarfGate.Sarif.generate(gate_result)

    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    Enum.each(run["results"], fn result ->
      [location] = result["locations"]
      assert location["physicalLocation"]["artifactLocation"]["uri"] =~ "github.com"
      assert location["physicalLocation"]["artifactLocation"]["uriBaseId"] == "SRCROOT"
    end)
  end
end
