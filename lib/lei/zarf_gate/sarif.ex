# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.ZarfGate.Sarif do
  @moduledoc """
  SARIF (Static Analysis Results Interchange Format) v2.1.0 output
  for LEI Zarf Gate results.

  Produces SARIF JSON suitable for upload to GitHub Security tab
  or other SARIF-consuming tools.
  """

  @sarif_version "2.1.0"
  @sarif_schema "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json"

  @doc """
  Generate SARIF v2.1.0 JSON from a gate result.
  """
  @spec generate(map()) :: {:ok, String.t()}
  def generate(gate_result) do
    sarif = %{
      "$schema" => @sarif_schema,
      "version" => @sarif_version,
      "runs" => [
        %{
          "tool" => tool_component(),
          "results" => build_results(gate_result),
          "invocations" => [
            %{
              "executionSuccessful" => true,
              "endTimeUtc" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          ]
        }
      ]
    }

    {:ok, Poison.encode!(sarif, pretty: true)}
  end

  defp tool_component do
    %{
      "driver" => %{
        "name" => "lei-zarf-gate",
        "version" => "0.1.0",
        "informationUri" => "https://github.com/kitplummer/lowendinsight",
        "rules" => rules()
      }
    }
  end

  defp rules do
    [
      rule("lei/contributor-risk", "Contributor Risk",
        "Repository has insufficient contributor diversity",
        "warning"
      ),
      rule("lei/commit-currency-risk", "Commit Currency Risk",
        "Repository has not been updated recently",
        "warning"
      ),
      rule("lei/functional-contributors-risk", "Functional Contributors Risk",
        "Repository has too few functional contributors",
        "warning"
      ),
      rule("lei/large-recent-commit-risk", "Large Recent Commit Risk",
        "Repository has large recent commits indicating code volatility",
        "note"
      ),
      rule("lei/overall-risk", "Overall Supply Chain Risk",
        "Repository exceeds acceptable supply chain risk threshold",
        "error"
      )
    ]
  end

  defp rule(id, name, description, default_level) do
    %{
      "id" => id,
      "name" => name,
      "shortDescription" => %{"text" => description},
      "defaultConfiguration" => %{"level" => default_level}
    }
  end

  defp build_results(gate_result) do
    gate_result.failing_repos
    |> Enum.flat_map(&repo_to_results/1)
  end

  defp repo_to_results(entry) do
    results = entry.results
    repo = entry.repo

    risk_checks = [
      {"lei/contributor-risk", :contributor_risk, "contributor_risk"},
      {"lei/commit-currency-risk", :commit_currency_risk, "commit_currency_risk"},
      {"lei/functional-contributors-risk", :functional_contributors_risk,
       "functional_contributors_risk"},
      {"lei/large-recent-commit-risk", :large_recent_commit_risk, "large_recent_commit_risk"}
    ]

    individual_results =
      risk_checks
      |> Enum.filter(fn {_rule_id, key, str_key} ->
        val = Map.get(results, key) || Map.get(results, str_key)
        val in ["high", "critical"]
      end)
      |> Enum.map(fn {rule_id, key, str_key} ->
        val = Map.get(results, key) || Map.get(results, str_key)
        sarif_result(rule_id, val, repo)
      end)

    overall =
      sarif_result("lei/overall-risk", entry.risk, repo)

    [overall | individual_results]
  end

  defp sarif_result(rule_id, risk_level, repo) do
    %{
      "ruleId" => rule_id,
      "level" => risk_to_sarif_level(risk_level),
      "message" => %{
        "text" => "#{rule_id}: #{risk_level} risk detected for #{repo}"
      },
      "locations" => [
        %{
          "physicalLocation" => %{
            "artifactLocation" => %{
              "uri" => repo,
              "uriBaseId" => "SRCROOT"
            }
          }
        }
      ]
    }
  end

  defp risk_to_sarif_level("critical"), do: "error"
  defp risk_to_sarif_level("high"), do: "warning"
  defp risk_to_sarif_level("medium"), do: "note"
  defp risk_to_sarif_level(_), do: "none"
end
