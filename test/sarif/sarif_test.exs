# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.SarifTest do
  use ExUnit.Case, async: true

  @single_report %{
    header: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      start_time: "2024-01-01T00:00:00Z",
      end_time: "2024-01-01T00:00:05Z",
      duration: 5,
      uuid: "test-uuid-1234",
      source_client: "test",
      library_version: "0.9.0"
    },
    data: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      git: %{
        hash: "abc123def",
        default_branch: "main"
      },
      project_types: %{mix: "mix.exs"},
      risk: "critical",
      results: %{
        contributor_count: 1,
        contributor_risk: "critical",
        commit_currency_weeks: 563,
        commit_currency_risk: "critical",
        functional_contributors_risk: "critical",
        functional_contributors: 1,
        large_recent_commit_risk: "low",
        recent_commit_size_in_percent_of_codebase: 0.003683,
        sbom_risk: "medium",
        risk: "critical"
      }
    }
  }

  @multi_report %{
    state: :complete,
    report: %{
      uuid: "multi-uuid-5678",
      repos: [
        %{
          header: %{
            repo: "https://github.com/kitplummer/xmpp4rails",
            start_time: "2024-01-01T00:00:00Z",
            uuid: "repo-uuid-1"
          },
          data: %{
            repo: "https://github.com/kitplummer/xmpp4rails",
            git: %{hash: "abc123"},
            project_types: %{mix: "mix.exs"},
            results: %{
              contributor_count: 1,
              contributor_risk: "critical",
              commit_currency_weeks: 100,
              commit_currency_risk: "critical",
              functional_contributors_risk: "critical",
              functional_contributors: 1,
              large_recent_commit_risk: "low",
              recent_commit_size_in_percent_of_codebase: 0.01,
              sbom_risk: "medium",
              risk: "critical"
            }
          }
        },
        %{
          header: %{
            repo: "https://github.com/elixir-lang/elixir",
            start_time: "2024-01-01T00:00:00Z",
            uuid: "repo-uuid-2"
          },
          data: %{
            repo: "https://github.com/elixir-lang/elixir",
            git: %{hash: "def456"},
            project_types: %{mix: "mix.exs"},
            results: %{
              contributor_count: 150,
              contributor_risk: "low",
              commit_currency_weeks: 1,
              commit_currency_risk: "low",
              functional_contributors_risk: "low",
              functional_contributors: 20,
              large_recent_commit_risk: "low",
              recent_commit_size_in_percent_of_codebase: 0.001,
              sbom_risk: "low",
              risk: "low"
            }
          }
        }
      ]
    },
    metadata: %{
      repo_count: 2,
      times: %{start_time: "2024-01-01T00:00:00Z"}
    }
  }

  test "generates valid SARIF 2.1.0 structure from single report" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)

    assert sarif["$schema"] == "https://json.schemastore.org/sarif-2.1.0.json"
    assert sarif["version"] == "2.1.0"
    assert length(sarif["runs"]) == 1

    [run] = sarif["runs"]
    assert run["tool"]["driver"]["name"] == "LowEndInsight"
    assert is_list(run["tool"]["driver"]["rules"])
    assert length(run["tool"]["driver"]["rules"]) == 5
    assert run["automationDetails"]["id"] == "lowendinsight/supply-chain-risk"
  end

  test "produces results for non-low risk findings" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    results = run["results"]

    # Should have results for critical/high/medium risks but NOT low
    rule_ids = Enum.map(results, & &1["ruleId"]) |> Enum.uniq()

    assert "lei/contributor-risk" in rule_ids
    assert "lei/commit-currency" in rule_ids
    assert "lei/functional-contributors" in rule_ids
    assert "lei/sbom-missing" in rule_ids
    # large_recent_commit_risk is "low" so should NOT appear
    refute "lei/large-recent-commit" in rule_ids
  end

  test "maps critical risk to error level" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    contributor_result =
      Enum.find(run["results"], &(&1["ruleId"] == "lei/contributor-risk"))

    assert contributor_result["level"] == "error"
  end

  test "maps medium risk to note level" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    sbom_result =
      Enum.find(run["results"], &(&1["ruleId"] == "lei/sbom-missing"))

    assert sbom_result["level"] == "note"
  end

  test "includes physical location pointing at manifest file" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    [first_result | _] = run["results"]

    [location] = first_result["locations"]
    phys = location["physicalLocation"]
    assert phys["artifactLocation"]["uri"] == "mix.exs"
    assert phys["artifactLocation"]["uriBaseId"] == "%SRCROOT%"
    assert phys["region"]["startLine"] == 1
  end

  test "includes partial fingerprints for deduplication" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]
    [first_result | _] = run["results"]

    assert is_binary(first_result["partialFingerprints"]["primaryLocationLineHash"])
    assert String.contains?(first_result["partialFingerprints"]["primaryLocationLineHash"], "xmpp4rails")
  end

  test "generates results from multi-repo report" do
    {:ok, json} = Lei.Sarif.generate(@multi_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    # xmpp4rails has critical risks, elixir has all low
    # So results should only come from xmpp4rails
    results = run["results"]
    assert length(results) > 0

    repos_in_results =
      results
      |> Enum.map(& &1["properties"]["lei:analyzed_repo"])
      |> Enum.uniq()

    assert "https://github.com/kitplummer/xmpp4rails" in repos_in_results
    refute "https://github.com/elixir-lang/elixir" in repos_in_results
  end

  test "rules have security tag and security-severity" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    Enum.each(run["tool"]["driver"]["rules"], fn rule ->
      assert "security" in rule["properties"]["tags"]
      assert is_binary(rule["properties"]["security-severity"])
    end)
  end

  test "result messages include dependency name and risk" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    contributor_result =
      Enum.find(run["results"], &(&1["ruleId"] == "lei/contributor-risk"))

    assert String.contains?(contributor_result["message"]["text"], "xmpp4rails")
    assert String.contains?(contributor_result["message"]["text"], "critical")
  end

  test "returns error for unsupported format" do
    assert {:error, _} = Lei.Sarif.generate(%{bad: "data"})
  end

  test "rules have required SARIF fields" do
    {:ok, json} = Lei.Sarif.generate(@single_report)
    sarif = Poison.decode!(json)
    [run] = sarif["runs"]

    Enum.each(run["tool"]["driver"]["rules"], fn rule ->
      assert is_binary(rule["id"])
      assert is_binary(rule["name"])
      assert is_map(rule["shortDescription"])
      assert is_binary(rule["shortDescription"]["text"])
      assert is_map(rule["fullDescription"])
      assert is_binary(rule["fullDescription"]["text"])
      assert is_map(rule["help"])
      assert is_binary(rule["help"]["markdown"])
      assert is_map(rule["defaultConfiguration"])
    end)
  end
end
