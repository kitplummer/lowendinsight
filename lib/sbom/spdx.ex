# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Sbom.SPDX do
  @moduledoc """
  Generates SPDX 2.3 JSON SBOM documents from LowEndInsight analysis reports.
  Embeds bus-factor risk scores as annotations on each package.
  """

  @spdx_version "SPDX-2.3"
  @data_license "CC0-1.0"

  @doc """
  Generates an SPDX 2.3 JSON string from a LowEndInsight report map.
  Supports both single-repo and multi-repo report formats.
  """
  @spec generate(map()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(%{report: %{repos: repos}} = report) do
    doc_uuid = UUID.uuid1()
    packages = Enum.map(repos, &repo_to_package/1)
    annotations = repos |> Enum.flat_map(&repo_to_annotations/1)

    relationships =
      packages
      |> Enum.map(fn pkg ->
        %{
          spdxElementId: "SPDXRef-DOCUMENT",
          relationshipType: "DESCRIBES",
          relatedSpdxElement: pkg[:SPDXID]
        }
      end)

    timestamp =
      case report do
        %{metadata: %{times: %{start_time: t}}} -> t
        _ -> DateTime.to_iso8601(DateTime.utc_now())
      end

    doc = %{
      spdxVersion: @spdx_version,
      dataLicense: @data_license,
      SPDXID: "SPDXRef-DOCUMENT",
      name: "lowendinsight-sbom",
      documentNamespace: "https://lowendinsight.gtri.gatech.edu/spdx/#{doc_uuid}",
      creationInfo: %{
        created: timestamp,
        creators: ["Tool: LowEndInsight-#{lowendinsight_version()}"],
        licenseListVersion: "3.19"
      },
      packages: packages,
      relationships: relationships,
      annotations: annotations
    }

    {:ok, Poison.encode!(doc, pretty: true)}
  end

  def generate(%{header: _header, data: _data} = report) do
    doc_uuid = UUID.uuid1()
    package = single_repo_to_package(report)
    annotations = single_repo_to_annotations(report)

    doc = %{
      spdxVersion: @spdx_version,
      dataLicense: @data_license,
      SPDXID: "SPDXRef-DOCUMENT",
      name: "lowendinsight-sbom",
      documentNamespace: "https://lowendinsight.gtri.gatech.edu/spdx/#{doc_uuid}",
      creationInfo: %{
        created: report.header[:start_time] || report.header.start_time,
        creators: [
          "Tool: LowEndInsight-#{Map.get(report.header, :library_version, lowendinsight_version())}"
        ],
        licenseListVersion: "3.19"
      },
      packages: [package],
      relationships: [
        %{
          spdxElementId: "SPDXRef-DOCUMENT",
          relationshipType: "DESCRIBES",
          relatedSpdxElement: package[:SPDXID]
        }
      ],
      annotations: annotations
    }

    {:ok, Poison.encode!(doc, pretty: true)}
  end

  def generate(_), do: {:error, "unsupported report format"}

  defp repo_to_package(repo_report) do
    data = repo_report[:data] || repo_report.data
    header = repo_report[:header] || repo_report.header
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    spdx_id = "SPDXRef-Package-#{sanitize_spdx_id(name)}"
    git_info = data[:git] || data.git || %{}

    %{
      SPDXID: spdx_id,
      name: name,
      versionInfo: Map.get(git_info, :hash, "NOASSERTION"),
      downloadLocation: repo_url,
      supplier: "NOASSERTION",
      filesAnalyzed: false,
      primaryPackagePurpose: "LIBRARY",
      externalRefs: [
        %{
          referenceCategory: "PACKAGE-MANAGER",
          referenceType: "purl",
          referenceLocator: "pkg:github/#{slug}"
        }
      ],
      comment: build_risk_comment(data, header)
    }
  end

  defp single_repo_to_package(%{header: header, data: data}) do
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    spdx_id = "SPDXRef-Package-#{sanitize_spdx_id(name)}"
    git_info = data[:git] || data.git || %{}

    %{
      SPDXID: spdx_id,
      name: name,
      versionInfo: Map.get(git_info, :hash, "NOASSERTION"),
      downloadLocation: repo_url,
      supplier: "NOASSERTION",
      filesAnalyzed: false,
      primaryPackagePurpose: "LIBRARY",
      externalRefs: [
        %{
          referenceCategory: "PACKAGE-MANAGER",
          referenceType: "purl",
          referenceLocator: "pkg:github/#{slug}"
        }
      ],
      comment: build_risk_comment(data, header)
    }
  end

  defp repo_to_annotations(repo_report) do
    data = repo_report[:data] || repo_report.data
    header = repo_report[:header] || repo_report.header
    results = data[:results] || data.results
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    spdx_id = "SPDXRef-Package-#{sanitize_spdx_id(name)}"
    timestamp = header[:start_time] || header.start_time

    risk_annotations(spdx_id, timestamp, results)
  end

  defp single_repo_to_annotations(%{header: header, data: data}) do
    results = data[:results] || data.results
    repo_url = data[:repo] || data.repo

    {:ok, slug} = Helpers.get_slug(repo_url)
    name = slug |> String.split("/") |> List.last()
    spdx_id = "SPDXRef-Package-#{sanitize_spdx_id(name)}"
    timestamp = header[:start_time] || header.start_time

    risk_annotations(spdx_id, timestamp, results)
  end

  defp risk_annotations(spdx_id, timestamp, results) when is_map(results) do
    risk_fields = [
      {"overall_risk", results[:risk] || Map.get(results, :risk)},
      {"contributor_risk", results[:contributor_risk] || Map.get(results, :contributor_risk)},
      {"contributor_count", results[:contributor_count] || Map.get(results, :contributor_count)},
      {"commit_currency_risk",
       results[:commit_currency_risk] || Map.get(results, :commit_currency_risk)},
      {"commit_currency_weeks",
       results[:commit_currency_weeks] || Map.get(results, :commit_currency_weeks)},
      {"functional_contributors_risk",
       results[:functional_contributors_risk] ||
         Map.get(results, :functional_contributors_risk)},
      {"functional_contributors",
       results[:functional_contributors] || Map.get(results, :functional_contributors)},
      {"large_recent_commit_risk",
       results[:large_recent_commit_risk] || Map.get(results, :large_recent_commit_risk)},
      {"sbom_risk", results[:sbom_risk] || Map.get(results, :sbom_risk)}
    ]

    [
      %{
        annotationDate: timestamp,
        annotationType: "REVIEW",
        annotator: "Tool: LowEndInsight",
        comment:
          risk_fields
          |> Enum.map(fn {k, v} -> "lei:#{k}=#{v}" end)
          |> Enum.join("; "),
        SPDXID: spdx_id
      }
    ]
  end

  defp risk_annotations(_, _, _), do: []

  defp build_risk_comment(data, _header) do
    results = data[:results] || data.results || %{}

    risk = results[:risk] || Map.get(results, :risk, "undetermined")
    contributor_risk = results[:contributor_risk] || Map.get(results, :contributor_risk, "")
    commit_risk = results[:commit_currency_risk] || Map.get(results, :commit_currency_risk, "")

    "LowEndInsight risk=#{risk}; contributor_risk=#{contributor_risk}; commit_currency_risk=#{commit_risk}"
  end

  defp sanitize_spdx_id(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  end

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
