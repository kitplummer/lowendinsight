# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Sbom.CycloneDX do
  @moduledoc """
  Generates CycloneDX 1.4 JSON SBOM documents from LowEndInsight analysis reports.
  Embeds bus-factor risk scores as custom properties on each component.
  """

  @spec_version "1.4"
  @bom_format "CycloneDX"

  @doc """
  Generates a CycloneDX 1.4 JSON string from a LowEndInsight report map.
  The report should be the result of `AnalyzerModule.analyze/3` for a single repo,
  or `AnalyzerModule.analyze/4` for multiple repos.
  """
  @spec generate(map()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(%{report: %{repos: repos}} = report) do
    components =
      repos
      |> Enum.with_index()
      |> Enum.map(fn {repo_report, _idx} -> repo_to_component(repo_report) end)

    bom = %{
      bomFormat: @bom_format,
      specVersion: @spec_version,
      serialNumber: "urn:uuid:#{UUID.uuid1()}",
      version: 1,
      metadata: build_metadata(report),
      components: components
    }

    {:ok, Poison.encode!(bom, pretty: true)}
  end

  def generate(%{header: _header, data: _data} = report) do
    component = single_repo_to_component(report)

    bom = %{
      bomFormat: @bom_format,
      specVersion: @spec_version,
      serialNumber: "urn:uuid:#{UUID.uuid1()}",
      version: 1,
      metadata: build_metadata_single(report),
      components: [component]
    }

    {:ok, Poison.encode!(bom, pretty: true)}
  end

  def generate(_), do: {:error, "unsupported report format"}

  defp build_metadata(report) do
    timestamp =
      case report do
        %{metadata: %{times: %{start_time: t}}} -> t
        _ -> DateTime.to_iso8601(DateTime.utc_now())
      end

    %{
      timestamp: timestamp,
      tools: [
        %{
          vendor: "GTRI",
          name: "LowEndInsight",
          version: lowendinsight_version()
        }
      ]
    }
  end

  defp build_metadata_single(%{header: header}) do
    %{
      timestamp: header[:start_time] || header.start_time,
      tools: [
        %{
          vendor: "GTRI",
          name: "LowEndInsight",
          version: Map.get(header, :library_version, lowendinsight_version())
        }
      ]
    }
  end

  defp repo_to_component(repo_report) do
    data = repo_report[:data] || repo_report.data
    header = repo_report[:header] || repo_report.header
    results = data[:results] || data.results
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    group = slug |> String.split("/") |> List.first()

    git_info = data[:git] || data.git || %{}

    component = %{
      type: "library",
      "bom-ref": Map.get(header, :uuid, UUID.uuid1()),
      group: group,
      name: name,
      version: Map.get(git_info, :hash, "unknown"),
      purl: build_purl(repo_url, git_info),
      externalReferences: [
        %{type: "vcs", url: repo_url}
      ],
      properties: build_risk_properties(results)
    }

    component
  end

  defp single_repo_to_component(%{header: header, data: data}) do
    results = data[:results] || data.results
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    group = slug |> String.split("/") |> List.first()

    git_info = data[:git] || data.git || %{}

    %{
      type: "library",
      "bom-ref": Map.get(header, :uuid, UUID.uuid1()),
      group: group,
      name: name,
      version: Map.get(git_info, :hash, "unknown"),
      purl: build_purl(repo_url, git_info),
      externalReferences: [
        %{type: "vcs", url: repo_url}
      ],
      properties: build_risk_properties(results)
    }
  end

  defp build_risk_properties(results) when is_map(results) do
    [
      %{name: "lei:risk", value: to_string(results[:risk] || Map.get(results, :risk, ""))},
      %{
        name: "lei:contributor_risk",
        value: to_string(results[:contributor_risk] || Map.get(results, :contributor_risk, ""))
      },
      %{
        name: "lei:contributor_count",
        value: to_string(results[:contributor_count] || Map.get(results, :contributor_count, ""))
      },
      %{
        name: "lei:commit_currency_risk",
        value:
          to_string(
            results[:commit_currency_risk] || Map.get(results, :commit_currency_risk, "")
          )
      },
      %{
        name: "lei:commit_currency_weeks",
        value:
          to_string(
            results[:commit_currency_weeks] || Map.get(results, :commit_currency_weeks, "")
          )
      },
      %{
        name: "lei:functional_contributors_risk",
        value:
          to_string(
            results[:functional_contributors_risk] ||
              Map.get(results, :functional_contributors_risk, "")
          )
      },
      %{
        name: "lei:functional_contributors",
        value:
          to_string(
            results[:functional_contributors] || Map.get(results, :functional_contributors, "")
          )
      },
      %{
        name: "lei:large_recent_commit_risk",
        value:
          to_string(
            results[:large_recent_commit_risk] ||
              Map.get(results, :large_recent_commit_risk, "")
          )
      },
      %{
        name: "lei:sbom_risk",
        value: to_string(results[:sbom_risk] || Map.get(results, :sbom_risk, ""))
      }
    ]
  end

  defp build_risk_properties(_), do: []

  defp build_purl(repo_url, git_info) do
    case Helpers.get_slug(repo_url) do
      {:ok, slug} ->
        version = Map.get(git_info, :hash, "")
        qualifier = if version != "", do: "?vcs_url=#{URI.encode(repo_url)}", else: ""
        "pkg:github/#{slug}#{qualifier}"

      _ ->
        ""
    end
  end

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
