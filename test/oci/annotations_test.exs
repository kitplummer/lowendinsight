# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.OCI.AnnotationsTest do
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

  describe "from_report/1 with single report" do
    test "generates annotations with dev.lowendinsight prefix" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@single_report)

      assert annotations["dev.lowendinsight.risk"] == "critical"
      assert annotations["dev.lowendinsight.contributor-risk"] == "critical"
      assert annotations["dev.lowendinsight.contributor-count"] == "1"
      assert annotations["dev.lowendinsight.commit-currency-risk"] == "critical"
      assert annotations["dev.lowendinsight.commit-currency-weeks"] == "563"
      assert annotations["dev.lowendinsight.functional-contributors-risk"] == "critical"
      assert annotations["dev.lowendinsight.functional-contributors"] == "1"
      assert annotations["dev.lowendinsight.large-recent-commit-risk"] == "low"
      assert annotations["dev.lowendinsight.sbom-risk"] == "medium"
    end

    test "includes metadata annotations" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@single_report)

      assert annotations["dev.lowendinsight.analyzed-at"] == "2024-01-01T00:00:00Z"
      assert annotations["dev.lowendinsight.version"] == "0.9.0"
      assert annotations["dev.lowendinsight.source-repo"] == "https://github.com/kitplummer/xmpp4rails"
    end

    test "all values are strings" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@single_report)

      Enum.each(annotations, fn {_key, value} ->
        assert is_binary(value), "Expected string value, got: #{inspect(value)}"
      end)
    end

    test "all keys use dev.lowendinsight prefix" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@single_report)

      Enum.each(annotations, fn {key, _value} ->
        assert String.starts_with?(key, "dev.lowendinsight."),
               "Key #{key} does not start with dev.lowendinsight."
      end)
    end
  end

  describe "from_report/1 with multi-repo report" do
    test "generates annotations for single-repo multi-report" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@multi_report)

      assert annotations["dev.lowendinsight.risk"] == "critical"
      assert annotations["dev.lowendinsight.source-repo"] == "https://github.com/kitplummer/xmpp4rails"
    end

    test "uses metadata timestamp when available" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@multi_report)

      assert annotations["dev.lowendinsight.analyzed-at"] == "2024-01-01T00:00:00Z"
    end

    test "falls back to header timestamp when metadata.times is missing" do
      report_no_times = %{
        report: %{
          repos: [
            %{
              header: %{
                repo: "https://github.com/test/repo",
                start_time: "2024-06-01T00:00:00Z",
                uuid: "test-uuid"
              },
              data: %{
                repo: "https://github.com/test/repo",
                git: %{hash: "abc"},
                results: %{risk: "low"}
              }
            }
          ]
        },
        metadata: %{repo_count: 1}
      }

      {:ok, annotations} = Lei.OCI.Annotations.from_report(report_no_times)
      assert annotations["dev.lowendinsight.analyzed-at"] == "2024-06-01T00:00:00Z"
    end

    test "handles nil results with empty risk annotations" do
      report = %{
        report: %{
          repos: [
            %{
              header: %{repo: "https://github.com/test/repo", start_time: "2024-01-01T00:00:00Z", uuid: "t"},
              data: %{repo: "https://github.com/test/repo", results: nil}
            }
          ]
        },
        metadata: %{repo_count: 1, times: %{start_time: "2024-01-01T00:00:00Z"}}
      }

      {:ok, annotations} = Lei.OCI.Annotations.from_report(report)
      refute Map.has_key?(annotations, "dev.lowendinsight.risk")
      assert annotations["dev.lowendinsight.source-repo"] == "https://github.com/test/repo"
    end

    test "returns error for multi-repo reports with multiple repos" do
      multi_multi = put_in(@multi_report, [:report, :repos], [
        hd(@multi_report.report.repos),
        hd(@multi_report.report.repos)
      ])

      assert {:error, _reason} = Lei.OCI.Annotations.from_report(multi_multi)
    end
  end

  describe "from_report/1 error handling" do
    test "returns error for unsupported format" do
      assert {:error, _} = Lei.OCI.Annotations.from_report(%{bad: "data"})
    end

    test "handles missing results gracefully" do
      report = %{
        header: %{start_time: "2024-01-01T00:00:00Z", library_version: "0.9.0"},
        data: %{repo: "https://github.com/org/repo", results: %{}}
      }

      {:ok, annotations} = Lei.OCI.Annotations.from_report(report)
      assert annotations["dev.lowendinsight.source-repo"] == "https://github.com/org/repo"
      assert annotations["dev.lowendinsight.analyzed-at"] == "2024-01-01T00:00:00Z"
    end
  end

  describe "from_results/3" do
    test "generates annotations from raw results" do
      results = %{
        risk: "high",
        contributor_count: 3,
        contributor_risk: "high",
        commit_currency_weeks: 30,
        commit_currency_risk: "medium"
      }

      {:ok, annotations} =
        Lei.OCI.Annotations.from_results(
          results,
          "https://github.com/org/repo",
          "2024-06-15T12:00:00Z"
        )

      assert annotations["dev.lowendinsight.risk"] == "high"
      assert annotations["dev.lowendinsight.contributor-count"] == "3"
      assert annotations["dev.lowendinsight.commit-currency-weeks"] == "30"
      assert annotations["dev.lowendinsight.source-repo"] == "https://github.com/org/repo"
      assert annotations["dev.lowendinsight.analyzed-at"] == "2024-06-15T12:00:00Z"
    end

    test "omits keys not present in results" do
      results = %{risk: "low"}

      {:ok, annotations} =
        Lei.OCI.Annotations.from_results(results, "https://github.com/org/repo", "2024-01-01T00:00:00Z")

      assert annotations["dev.lowendinsight.risk"] == "low"
      refute Map.has_key?(annotations, "dev.lowendinsight.contributor-risk")
      refute Map.has_key?(annotations, "dev.lowendinsight.sbom-risk")
    end
  end

  describe "to_json/1" do
    test "encodes annotations as JSON" do
      {:ok, annotations} = Lei.OCI.Annotations.from_report(@single_report)
      {:ok, json} = Lei.OCI.Annotations.to_json(annotations)

      decoded = Poison.decode!(json)
      assert decoded["dev.lowendinsight.risk"] == "critical"
      assert decoded["dev.lowendinsight.contributor-count"] == "1"
    end
  end

  describe "to_cli_flags/1" do
    test "generates sorted --annotation flags" do
      annotations = %{
        "dev.lowendinsight.risk" => "critical",
        "dev.lowendinsight.contributor-count" => "1"
      }

      flags = Lei.OCI.Annotations.to_cli_flags(annotations)

      assert "--annotation dev.lowendinsight.contributor-count=1" in flags
      assert "--annotation dev.lowendinsight.risk=critical" in flags
      assert length(flags) == 2
    end

    test "flags are sorted alphabetically by key" do
      annotations = %{
        "dev.lowendinsight.risk" => "critical",
        "dev.lowendinsight.analyzed-at" => "2024-01-01T00:00:00Z",
        "dev.lowendinsight.contributor-count" => "1"
      }

      flags = Lei.OCI.Annotations.to_cli_flags(annotations)

      assert List.first(flags) =~ "analyzed-at"
      assert List.last(flags) =~ "risk"
    end
  end
end
