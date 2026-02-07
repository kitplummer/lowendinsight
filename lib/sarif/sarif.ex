# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Sarif do
  @moduledoc """
  Converts LowEndInsight analysis reports to SARIF 2.1.0 format for
  GitHub Code Scanning / Security tab integration.
  """

  @sarif_version "2.1.0"
  @schema_uri "https://json.schemastore.org/sarif-2.1.0.json"

  @rules [
    %{
      id: "lei/contributor-risk",
      name: "ContributorRisk",
      short_description: "Low contributor count indicates bus-factor risk",
      full_description:
        "A dependency with very few unique contributors has a high bus-factor risk. " <>
          "If those contributors become unavailable, the project may become unmaintained.",
      help_markdown:
        "## Contributor / Bus-Factor Risk\n\n" <>
          "Measures unique contributors to a dependency's git history.\n\n" <>
          "| Contributors | Risk |\n|---|---|\n" <>
          "| < 2 | **Critical** |\n| < 3 | High |\n| < 5 | Medium |\n| >= 5 | Low |",
      tags: ["security", "supply-chain", "bus-factor"],
      default_severity: "7.0",
      result_key: :contributor_risk,
      message_fn: &Lei.Sarif.contributor_message/2
    },
    %{
      id: "lei/commit-currency",
      name: "CommitCurrencyRisk",
      short_description: "Stale dependency has not been committed to recently",
      full_description:
        "A dependency whose last commit was long ago may be abandoned or unmaintained, " <>
          "posing a supply-chain risk if vulnerabilities are discovered.",
      help_markdown:
        "## Commit Currency Risk\n\n" <>
          "Measures time since the last commit on the default branch.\n\n" <>
          "| Weeks Since Last Commit | Risk |\n|---|---|\n" <>
          "| >= 52 | **Critical** |\n| 26-51 | Medium |\n| < 26 | Low |",
      tags: ["security", "supply-chain", "maintenance"],
      default_severity: "6.0",
      result_key: :commit_currency_risk,
      message_fn: &Lei.Sarif.commit_currency_message/2
    },
    %{
      id: "lei/functional-contributors",
      name: "FunctionalContributorsRisk",
      short_description: "Too few active contributors with meaningful commit share",
      full_description:
        "Functional contributors are those with a significant share of commits. " <>
          "A project where only 1-2 people do the real work has high bus-factor risk.",
      help_markdown:
        "## Functional Contributors Risk\n\n" <>
          "Counts contributors with a significant percentage of total commits.\n\n" <>
          "| Functional Contributors | Risk |\n|---|---|\n" <>
          "| < 2 | **Critical** |\n| < 5 | High/Medium |\n| >= 5 | Low |",
      tags: ["security", "supply-chain", "bus-factor"],
      default_severity: "7.0",
      result_key: :functional_contributors_risk,
      message_fn: &Lei.Sarif.functional_contributors_message/2
    },
    %{
      id: "lei/large-recent-commit",
      name: "LargeRecentCommitRisk",
      short_description: "Last commit changed a large percentage of the codebase",
      full_description:
        "A recent commit that changes a disproportionately large percentage of the codebase " <>
          "could indicate a compromised account, force-push, or wholesale rewrite.",
      help_markdown:
        "## Large Recent Commit Risk\n\n" <>
          "Measures the most recent commit as a percentage of total codebase.\n\n" <>
          "| Change % | Risk |\n|---|---|\n" <>
          "| >= 50% | **Critical** |\n| >= 30% | High |\n| >= 20% | Medium |\n| < 20% | Low |",
      tags: ["security", "supply-chain", "integrity"],
      default_severity: "5.0",
      result_key: :large_recent_commit_risk,
      message_fn: &Lei.Sarif.large_commit_message/2
    },
    %{
      id: "lei/sbom-missing",
      name: "SbomRisk",
      short_description: "Dependency has elevated SBOM transparency risk",
      full_description:
        "The dependency repository may not contain a software bill of materials, " <>
          "reducing supply-chain transparency.",
      help_markdown:
        "## SBOM Risk\n\n" <>
          "Checks whether the dependency publishes a CycloneDX or SPDX SBOM file.",
      tags: ["security", "supply-chain", "transparency"],
      default_severity: "4.0",
      result_key: :sbom_risk,
      message_fn: &Lei.Sarif.sbom_message/2
    }
  ]

  @doc """
  Generates a SARIF 2.1.0 JSON string from a LowEndInsight multi-repo report.
  """
  @spec generate(map()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(%{report: %{repos: repos}} = _report) do
    results =
      repos
      |> Enum.flat_map(&repo_to_results/1)

    sarif = build_sarif(results)
    {:ok, Poison.encode!(sarif, pretty: true)}
  end

  def generate(%{header: _header, data: _data} = report) do
    results = repo_to_results(report)
    sarif = build_sarif(results)
    {:ok, Poison.encode!(sarif, pretty: true)}
  end

  def generate(_), do: {:error, "unsupported report format"}

  @doc false
  def rules, do: @rules

  defp build_sarif(results) do
    %{
      "$schema": @schema_uri,
      version: @sarif_version,
      runs: [
        %{
          tool: %{
            driver: %{
              name: "LowEndInsight",
              semanticVersion: lowendinsight_version(),
              informationUri: "https://github.com/gtri/lowendinsight",
              rules: Enum.map(@rules, &build_rule/1)
            }
          },
          automationDetails: %{
            id: "lowendinsight/supply-chain-risk"
          },
          results: results,
          columnKind: "utf16CodeUnits"
        }
      ]
    }
  end

  defp build_rule(rule) do
    %{
      id: rule.id,
      name: rule.name,
      shortDescription: %{text: rule.short_description},
      fullDescription: %{text: rule.full_description},
      helpUri: "https://github.com/gtri/lowendinsight",
      help: %{
        text: rule.short_description,
        markdown: rule.help_markdown
      },
      defaultConfiguration: %{
        level: "warning"
      },
      properties: %{
        tags: rule.tags,
        precision: "high",
        "security-severity": rule.default_severity
      }
    }
  end

  defp repo_to_results(repo_report) do
    data = repo_report[:data] || repo_report.data
    results = data[:results] || data.results
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    dep_name = slug |> String.split("/") |> List.last()

    manifest_uri = detect_manifest(data)

    @rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, rule_index} ->
      risk_level = get_in_results(results, rule.result_key)

      if risk_level && risk_level != "low" do
        [
          %{
            ruleId: rule.id,
            ruleIndex: rule_index,
            level: risk_to_level(risk_level),
            message: %{
              text: rule.message_fn.(dep_name, results)
            },
            locations: [
              %{
                physicalLocation: %{
                  artifactLocation: %{
                    uri: manifest_uri,
                    uriBaseId: "%SRCROOT%"
                  },
                  region: %{
                    startLine: 1,
                    startColumn: 1
                  }
                }
              }
            ],
            partialFingerprints: %{
              primaryLocationLineHash: "lei-#{rule_key(rule.id)}-#{dep_name}"
            },
            properties: %{
              "lei:risk_level": to_string(risk_level),
              "lei:analyzed_repo": repo_url
            }
          }
        ]
      else
        []
      end
    end)
  end

  defp detect_manifest(data) do
    project_types = data[:project_types] || Map.get(data, :project_types, %{})

    cond do
      is_map(project_types) && Map.has_key?(project_types, :mix) -> "mix.exs"
      is_map(project_types) && Map.has_key?(project_types, :node) -> "package.json"
      is_map(project_types) && Map.has_key?(project_types, :python) -> "requirements.txt"
      is_map(project_types) && Map.has_key?(project_types, :cargo) -> "Cargo.toml"
      true -> "mix.exs"
    end
  end

  defp get_in_results(results, key) when is_map(results) do
    results[key] || Map.get(results, key)
  end

  defp get_in_results(_, _), do: nil

  defp risk_to_level("critical"), do: "error"
  defp risk_to_level("high"), do: "warning"
  defp risk_to_level("medium"), do: "note"
  defp risk_to_level(_), do: "note"

  defp rule_key(id), do: id |> String.replace("lei/", "") |> String.replace("-", "_")

  @doc false
  def risk_to_security_severity("critical"), do: "9.1"
  def risk_to_security_severity("high"), do: "7.0"
  def risk_to_security_severity("medium"), do: "4.5"
  def risk_to_security_severity(_), do: "2.0"

  # Message functions for each rule type

  @doc false
  def contributor_message(dep_name, results) do
    count = get_in_results(results, :contributor_count) || "unknown"
    risk = get_in_results(results, :contributor_risk) || "unknown"
    "Dependency '#{dep_name}' has #{count} contributor(s). Contributor risk: #{risk}."
  end

  @doc false
  def commit_currency_message(dep_name, results) do
    weeks = get_in_results(results, :commit_currency_weeks) || "unknown"
    risk = get_in_results(results, :commit_currency_risk) || "unknown"
    "Dependency '#{dep_name}' last committed #{weeks} weeks ago. Commit currency risk: #{risk}."
  end

  @doc false
  def functional_contributors_message(dep_name, results) do
    count = get_in_results(results, :functional_contributors) || "unknown"
    risk = get_in_results(results, :functional_contributors_risk) || "unknown"

    "Dependency '#{dep_name}' has #{count} functional contributor(s). Functional contributors risk: #{risk}."
  end

  @doc false
  def large_commit_message(dep_name, results) do
    percent = get_in_results(results, :recent_commit_size_in_percent_of_codebase) || "unknown"
    risk = get_in_results(results, :large_recent_commit_risk) || "unknown"

    display =
      if is_number(percent),
        do: "#{Float.round(percent * 100, 2)}%",
        else: to_string(percent)

    "Dependency '#{dep_name}' last commit changed #{display} of codebase. Large recent commit risk: #{risk}."
  end

  @doc false
  def sbom_message(dep_name, results) do
    risk = get_in_results(results, :sbom_risk) || "unknown"
    "Dependency '#{dep_name}' SBOM risk: #{risk}."
  end

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
