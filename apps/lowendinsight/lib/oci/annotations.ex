# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.OCI.Annotations do
  @moduledoc """
  Generates OCI image annotations from LowEndInsight analysis reports.

  Annotations follow the `dev.lowendinsight.*` namespace using OCI annotation
  conventions (reverse-DNS prefix, hyphenated keys, string values).

  See `docs/OCI_ANNOTATION_SCHEMA.md` for the full schema specification.
  """

  @prefix "dev.lowendinsight"

  @risk_keys [
    {:risk, "risk"},
    {:contributor_risk, "contributor-risk"},
    {:contributor_count, "contributor-count"},
    {:commit_currency_risk, "commit-currency-risk"},
    {:commit_currency_weeks, "commit-currency-weeks"},
    {:functional_contributors_risk, "functional-contributors-risk"},
    {:functional_contributors, "functional-contributors"},
    {:large_recent_commit_risk, "large-recent-commit-risk"},
    {:sbom_risk, "sbom-risk"}
  ]

  @doc """
  Generates a map of OCI annotation key-value pairs from a single-repo LEI report.

  Returns `{:ok, map}` where all keys are `dev.lowendinsight.*` strings and all
  values are strings (per OCI spec). Returns `{:error, reason}` for unsupported formats.

  ## Examples

      iex> report = %{header: %{start_time: "2024-01-01T00:00:00Z"}, data: %{repo: "https://github.com/org/repo", results: %{risk: "critical", contributor_count: 1}}}
      iex> {:ok, annotations} = Lei.OCI.Annotations.from_report(report)
      iex> annotations["dev.lowendinsight.risk"]
      "critical"
  """
  @spec from_report(map()) :: {:ok, map()} | {:error, String.t()}
  def from_report(%{header: header, data: data}) do
    results = data[:results] || Map.get(data, :results, %{})
    repo_url = data[:repo] || Map.get(data, :repo, "")
    timestamp = header[:start_time] || Map.get(header, :start_time, "")
    version = Map.get(header, :library_version, lowendinsight_version())

    annotations =
      build_risk_annotations(results)
      |> Map.merge(%{
        "#{@prefix}.analyzed-at" => to_string(timestamp),
        "#{@prefix}.version" => to_string(version),
        "#{@prefix}.source-repo" => to_string(repo_url)
      })

    {:ok, annotations}
  end

  def from_report(%{report: %{repos: repos}} = report) do
    case repos do
      [single_repo] ->
        header = single_repo[:header] || single_repo.header
        data = single_repo[:data] || single_repo.data

        timestamp =
          case report do
            %{metadata: %{times: %{start_time: t}}} -> t
            _ -> header[:start_time] || Map.get(header, :start_time, "")
          end

        results = data[:results] || Map.get(data, :results, %{})
        repo_url = data[:repo] || Map.get(data, :repo, "")

        annotations =
          build_risk_annotations(results)
          |> Map.merge(%{
            "#{@prefix}.analyzed-at" => to_string(timestamp),
            "#{@prefix}.version" => lowendinsight_version(),
            "#{@prefix}.source-repo" => to_string(repo_url)
          })

        {:ok, annotations}

      _multiple ->
        {:error, "multi-repo reports must specify a single repo for OCI annotations"}
    end
  end

  def from_report(_), do: {:error, "unsupported report format"}

  @doc """
  Generates OCI annotations directly from a results map, repo URL, and timestamp.

  Useful when you already have extracted analysis results and don't need to
  parse a full report structure.
  """
  @spec from_results(map(), String.t(), String.t()) :: {:ok, map()}
  def from_results(results, repo_url, analyzed_at) when is_map(results) do
    annotations =
      build_risk_annotations(results)
      |> Map.merge(%{
        "#{@prefix}.analyzed-at" => to_string(analyzed_at),
        "#{@prefix}.version" => lowendinsight_version(),
        "#{@prefix}.source-repo" => to_string(repo_url)
      })

    {:ok, annotations}
  end

  @doc """
  Encodes annotations as a JSON string suitable for `--annotation-file` flags
  in OCI tooling (crane, oras, docker buildx).
  """
  @spec to_json(map()) :: {:ok, String.t()}
  def to_json(annotations) when is_map(annotations) do
    {:ok, Poison.encode!(annotations, pretty: true)}
  end

  @doc """
  Returns annotations as a list of `--annotation key=value` CLI flag strings,
  suitable for passing to `docker buildx build` or `oras push`.
  """
  @spec to_cli_flags(map()) :: [String.t()]
  def to_cli_flags(annotations) when is_map(annotations) do
    annotations
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> "--annotation #{k}=#{v}" end)
  end

  defp build_risk_annotations(results) when is_map(results) do
    @risk_keys
    |> Enum.reduce(%{}, fn {atom_key, annotation_key}, acc ->
      value = results[atom_key] || Map.get(results, atom_key)

      if value != nil do
        Map.put(acc, "#{@prefix}.#{annotation_key}", to_string(value))
      else
        acc
      end
    end)
  end

  defp build_risk_annotations(_), do: %{}

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
