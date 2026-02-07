# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.ZarfGate do
  @moduledoc """
  Pre-package risk gate for Zarf integration.

  Evaluates LEI analysis reports against configurable risk thresholds
  and returns pass/fail decisions suitable for use as a Zarf action hook
  or CI/CD gate.
  """

  @risk_levels %{"low" => 0, "medium" => 1, "high" => 2, "critical" => 3}

  @type gate_result :: %{
          pass: boolean(),
          threshold: String.t(),
          summary: %{
            total: non_neg_integer(),
            passing: non_neg_integer(),
            failing: non_neg_integer()
          },
          failing_repos: [map()],
          report: map()
        }

  @doc """
  Evaluate a single-repo LEI report against a risk threshold.

  Returns `{:ok, result}` where result contains `:pass` boolean and details.

  ## Threshold levels
    - "low" - fail on anything above low risk
    - "medium" - fail on high or critical risk
    - "high" - fail only on critical risk
    - "critical" - fail only on critical risk
  """
  @spec evaluate(map(), String.t()) :: {:ok, gate_result()}
  def evaluate(report, threshold \\ "high") do
    threshold = normalize_threshold(threshold)

    case detect_report_type(report) do
      :single ->
        evaluate_single(report, threshold)

      :multi ->
        evaluate_multi(report, threshold)

      :error ->
        {:error, "Unrecognized report format"}
    end
  end

  defp detect_report_type(%{data: %{risk: _risk}}), do: :single
  defp detect_report_type(%{report: %{repos: repos}}) when is_list(repos), do: :multi
  defp detect_report_type(_), do: :error

  defp evaluate_single(report, threshold) do
    risk = report[:data][:risk] || "undetermined"
    exceeds = exceeds_threshold?(risk, threshold)

    failing_repos =
      if exceeds do
        [build_failing_entry(report)]
      else
        []
      end

    {:ok,
     %{
       pass: !exceeds,
       threshold: threshold,
       summary: %{
         total: 1,
         passing: if(exceeds, do: 0, else: 1),
         failing: if(exceeds, do: 1, else: 0)
       },
       failing_repos: failing_repos,
       report: report
     }}
  end

  defp evaluate_multi(report, threshold) do
    repos = report[:report][:repos] || []

    {passing, failing} =
      Enum.split_with(repos, fn repo ->
        risk = get_in(repo, [:data, :risk]) || "undetermined"
        !exceeds_threshold?(risk, threshold)
      end)

    failing_entries = Enum.map(failing, &build_failing_entry_from_repo/1)

    {:ok,
     %{
       pass: Enum.empty?(failing),
       threshold: threshold,
       summary: %{
         total: length(repos),
         passing: length(passing),
         failing: length(failing)
       },
       failing_repos: failing_entries,
       report: report
     }}
  end

  @doc """
  Returns true if the given risk level exceeds the threshold.
  """
  @spec exceeds_threshold?(String.t(), String.t()) :: boolean()
  def exceeds_threshold?(risk, threshold) do
    risk_val = Map.get(@risk_levels, risk, -1)
    threshold_val = Map.get(@risk_levels, threshold, 2)
    risk_val >= threshold_val
  end

  defp normalize_threshold(threshold) when is_binary(threshold) do
    t = String.downcase(threshold)
    if Map.has_key?(@risk_levels, t), do: t, else: "high"
  end

  defp normalize_threshold(_), do: "high"

  defp build_failing_entry(report) do
    %{
      repo: report[:data][:repo] || report[:header][:repo] || "unknown",
      risk: report[:data][:risk] || "undetermined",
      results: report[:data][:results] || %{}
    }
  end

  defp build_failing_entry_from_repo(repo) do
    %{
      repo: get_in(repo, [:data, :repo]) || get_in(repo, [:header, :repo]) || "unknown",
      risk: get_in(repo, [:data, :risk]) || "undetermined",
      results: get_in(repo, [:data, :results]) || %{}
    }
  end

  @doc """
  Format gate result as JSON string.
  """
  @spec to_json(map()) :: {:ok, String.t()}
  def to_json(gate_result) do
    output = %{
      "lei-zarf-gate" => %{
        "version" => "0.1.0",
        "pass" => gate_result.pass,
        "threshold" => gate_result.threshold,
        "summary" => %{
          "total_dependencies" => gate_result.summary.total,
          "passing" => gate_result.summary.passing,
          "failing" => gate_result.summary.failing
        },
        "failing_dependencies" =>
          Enum.map(gate_result.failing_repos, fn entry ->
            %{
              "repo" => entry.repo,
              "risk" => entry.risk,
              "details" => format_results(entry.results)
            }
          end),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    {:ok, Poison.encode!(output, pretty: true)}
  end

  defp format_results(results) when is_map(results) do
    results
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp format_results(_), do: %{}
end
