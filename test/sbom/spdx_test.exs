# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Sbom.SPDXTest do
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
      risk: "critical",
      results: %{
        contributor_count: 1,
        contributor_risk: "critical",
        commit_currency_weeks: 563,
        commit_currency_risk: "critical",
        functional_contributors_risk: "critical",
        functional_contributors: 1,
        large_recent_commit_risk: "low",
        sbom_risk: "medium",
        risk: "critical"
      }
    }
  }

  @multi_report %{
    state: "complete",
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
            results: %{
              contributor_count: 1,
              contributor_risk: "critical",
              commit_currency_weeks: 100,
              commit_currency_risk: "critical",
              functional_contributors_risk: "critical",
              functional_contributors: 1,
              large_recent_commit_risk: "low",
              sbom_risk: "medium",
              risk: "critical"
            }
          }
        }
      ]
    },
    metadata: %{
      repo_count: 1,
      times: %{start_time: "2024-01-01T00:00:00Z"}
    }
  }

  test "generates valid SPDX 2.3 JSON from single report" do
    {:ok, json} = Lei.Sbom.SPDX.generate(@single_report)
    doc = Poison.decode!(json)

    assert doc["spdxVersion"] == "SPDX-2.3"
    assert doc["dataLicense"] == "CC0-1.0"
    assert doc["SPDXID"] == "SPDXRef-DOCUMENT"
    assert doc["name"] == "lowendinsight-sbom"
    assert String.contains?(doc["documentNamespace"], "lowendinsight.gtri.gatech.edu/spdx/")

    assert doc["creationInfo"]["created"] == "2024-01-01T00:00:00Z"
    [creator] = doc["creationInfo"]["creators"]
    assert String.starts_with?(creator, "Tool: LowEndInsight-")

    [package] = doc["packages"]
    assert package["name"] == "xmpp4rails"
    assert package["versionInfo"] == "abc123def"
    assert package["downloadLocation"] == "https://github.com/kitplummer/xmpp4rails"
    assert package["filesAnalyzed"] == false
    assert package["primaryPackagePurpose"] == "LIBRARY"
    assert String.starts_with?(package["SPDXID"], "SPDXRef-Package-")

    assert String.contains?(package["comment"], "risk=critical")
  end

  test "generates valid SPDX 2.3 JSON from multi-repo report" do
    {:ok, json} = Lei.Sbom.SPDX.generate(@multi_report)
    doc = Poison.decode!(json)

    assert doc["spdxVersion"] == "SPDX-2.3"
    assert length(doc["packages"]) == 1

    [package] = doc["packages"]
    assert package["name"] == "xmpp4rails"
  end

  test "includes DESCRIBES relationships" do
    {:ok, json} = Lei.Sbom.SPDX.generate(@single_report)
    doc = Poison.decode!(json)

    [rel] = doc["relationships"]
    assert rel["spdxElementId"] == "SPDXRef-DOCUMENT"
    assert rel["relationshipType"] == "DESCRIBES"
    assert String.starts_with?(rel["relatedSpdxElement"], "SPDXRef-Package-")
  end

  test "includes risk annotations" do
    {:ok, json} = Lei.Sbom.SPDX.generate(@single_report)
    doc = Poison.decode!(json)

    annotations = doc["annotations"]
    assert length(annotations) > 0

    [annotation] = annotations
    assert annotation["annotationType"] == "REVIEW"
    assert annotation["annotator"] == "Tool: LowEndInsight"
    assert String.contains?(annotation["comment"], "lei:overall_risk=critical")
    assert String.contains?(annotation["comment"], "lei:contributor_risk=critical")
    assert String.contains?(annotation["comment"], "lei:sbom_risk=medium")
  end

  test "includes purl external refs" do
    {:ok, json} = Lei.Sbom.SPDX.generate(@single_report)
    doc = Poison.decode!(json)

    [package] = doc["packages"]
    [ext_ref] = package["externalRefs"]
    assert ext_ref["referenceCategory"] == "PACKAGE-MANAGER"
    assert ext_ref["referenceType"] == "purl"
    assert ext_ref["referenceLocator"] == "pkg:github/kitplummer/xmpp4rails"
  end

  test "returns error for unsupported format" do
    assert {:error, _} = Lei.Sbom.SPDX.generate(%{bad: "data"})
  end
end
