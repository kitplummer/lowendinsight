# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Sbom.CycloneDXTest do
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

  test "generates valid CycloneDX 1.4 JSON from single report" do
    {:ok, json} = Lei.Sbom.CycloneDX.generate(@single_report)
    bom = Poison.decode!(json)

    assert bom["bomFormat"] == "CycloneDX"
    assert bom["specVersion"] == "1.4"
    assert bom["version"] == 1
    assert String.starts_with?(bom["serialNumber"], "urn:uuid:")

    assert bom["metadata"]["tools"] |> List.first() |> Map.get("name") == "LowEndInsight"

    [component] = bom["components"]
    assert component["type"] == "library"
    assert component["name"] == "xmpp4rails"
    assert component["group"] == "kitplummer"

    props = component["properties"]
    assert is_list(props)
    assert length(props) > 0

    risk_prop = Enum.find(props, &(&1["name"] == "lei:risk"))
    assert risk_prop["value"] == "critical"

    contributor_prop = Enum.find(props, &(&1["name"] == "lei:contributor_risk"))
    assert contributor_prop["value"] == "critical"

    sbom_prop = Enum.find(props, &(&1["name"] == "lei:sbom_risk"))
    assert sbom_prop["value"] == "medium"
  end

  test "generates valid CycloneDX 1.4 JSON from multi-repo report" do
    {:ok, json} = Lei.Sbom.CycloneDX.generate(@multi_report)
    bom = Poison.decode!(json)

    assert bom["bomFormat"] == "CycloneDX"
    assert bom["specVersion"] == "1.4"
    assert length(bom["components"]) == 1

    [component] = bom["components"]
    assert component["name"] == "xmpp4rails"
  end

  test "includes purl in components" do
    {:ok, json} = Lei.Sbom.CycloneDX.generate(@single_report)
    bom = Poison.decode!(json)
    [component] = bom["components"]

    assert String.starts_with?(component["purl"], "pkg:github/kitplummer/xmpp4rails")
  end

  test "includes external references" do
    {:ok, json} = Lei.Sbom.CycloneDX.generate(@single_report)
    bom = Poison.decode!(json)
    [component] = bom["components"]

    [ext_ref] = component["externalReferences"]
    assert ext_ref["type"] == "vcs"
    assert ext_ref["url"] == "https://github.com/kitplummer/xmpp4rails"
  end

  test "returns error for unsupported format" do
    assert {:error, _} = Lei.Sbom.CycloneDX.generate(%{bad: "data"})
  end

  test "handles report without timestamp in metadata" do
    report = %{
      state: "complete",
      report: %{
        uuid: "uuid",
        repos: [
          %{
            header: %{repo: "https://github.com/test/repo", uuid: "test"},
            data: %{
              repo: "https://github.com/test/repo",
              git: %{hash: "abc"},
              results: %{contributor_risk: "low"}
            }
          }
        ]
      },
      metadata: %{repo_count: 1}
    }

    {:ok, json} = Lei.Sbom.CycloneDX.generate(report)
    bom = Poison.decode!(json)

    assert is_binary(bom["metadata"]["timestamp"])
  end

  test "includes all risk properties in component" do
    {:ok, json} = Lei.Sbom.CycloneDX.generate(@single_report)
    bom = Poison.decode!(json)
    [component] = bom["components"]
    props = component["properties"]

    prop_names = Enum.map(props, & &1["name"])

    assert "lei:risk" in prop_names
    assert "lei:contributor_risk" in prop_names
    assert "lei:contributor_count" in prop_names
    assert "lei:commit_currency_risk" in prop_names
    assert "lei:commit_currency_weeks" in prop_names
    assert "lei:functional_contributors_risk" in prop_names
    assert "lei:functional_contributors" in prop_names
    assert "lei:large_recent_commit_risk" in prop_names
    assert "lei:sbom_risk" in prop_names
  end

  test "handles nil results with empty properties" do
    report = %{
      header: %{repo: "https://github.com/test/repo", uuid: "test", start_time: "2024-01-01T00:00:00Z"},
      data: %{
        repo: "https://github.com/test/repo",
        git: %{hash: "abc"},
        results: nil
      }
    }

    {:ok, json} = Lei.Sbom.CycloneDX.generate(report)
    bom = Poison.decode!(json)
    [component] = bom["components"]
    assert component["properties"] == []
  end

  test "handles nil results in multi-repo report" do
    report = %{
      state: "complete",
      report: %{
        uuid: "multi-uuid",
        repos: [
          %{
            header: %{repo: "https://github.com/test/repo", uuid: "test"},
            data: %{
              repo: "https://github.com/test/repo",
              git: %{hash: "abc"},
              results: nil
            }
          }
        ]
      },
      metadata: %{repo_count: 1}
    }

    {:ok, json} = Lei.Sbom.CycloneDX.generate(report)
    bom = Poison.decode!(json)
    [component] = bom["components"]
    assert component["properties"] == []
  end

  test "handles missing git hash gracefully" do
    report = %{
      header: %{repo: "https://github.com/test/repo", uuid: "test", start_time: "2024-01-01T00:00:00Z"},
      data: %{
        repo: "https://github.com/test/repo",
        git: %{},
        results: %{contributor_risk: "low"}
      }
    }

    {:ok, json} = Lei.Sbom.CycloneDX.generate(report)
    bom = Poison.decode!(json)
    [component] = bom["components"]

    assert component["version"] == "unknown"
  end
end
