# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule AnalyzerLocalTest do
  use ExUnit.Case, async: false

  test "analyze with https URL triggers ArgumentError rescue when config missing" do
    # Temporarily remove base_temp_dir config to trigger Application.fetch_env! ArgumentError
    original = Application.get_env(:lowendinsight, :base_temp_dir)
    Application.delete_env(:lowendinsight, :base_temp_dir)

    try do
      {:ok, report} =
        AnalyzerModule.analyze(
          "https://example.com/test/argtest-repo",
          "arg_error_test",
          %{}
        )

      assert report[:data][:error] =~ "Unable to analyze"
      assert report[:data][:risk] == "undetermined"
      assert report[:header][:source_client] == "arg_error_test"
      assert is_binary(report[:header][:uuid])
      assert is_binary(report[:header][:start_time])
      assert is_binary(report[:header][:end_time])
    after
      if original do
        Application.put_env(:lowendinsight, :base_temp_dir, original)
      else
        Application.put_env(:lowendinsight, :base_temp_dir, "/tmp")
      end
    end
  end

  test "analyze local path repo without network" do
    {:ok, cwd} = File.cwd()

    {:ok, report} =
      AnalyzerModule.analyze(["file:///#{cwd}"], "path_test", DateTime.utc_now(), %{types: false})

    assert "complete" == report[:state]
    repo_data = List.first(report[:report][:repos])
    assert "path_test" == repo_data[:header][:source_client]
    assert [] == repo_data[:data][:project_types]
  end

  test "analyze single repo with file:// scheme and types: true" do
    {:ok, cwd} = File.cwd()

    {:ok, report} =
      AnalyzerModule.analyze("file:///#{cwd}", "single_file_test", %{types: true})

    assert "single_file_test" == report[:header][:source_client]
    assert is_map(report[:data][:results])
    assert is_map(report[:data][:project_types])
    assert report[:data][:risk] in ["low", "medium", "high", "critical"]
  end

  test "analyze single repo with invalid file:// path returns error report" do
    {:ok, report} =
      AnalyzerModule.analyze(
        "file:///tmp/nonexistent_lei_test_#{:erlang.unique_integer([:positive])}",
        "error_test",
        %{}
      )

    assert report[:data][:error] =~ "Unable to analyze"
    assert report[:data][:risk] == "undetermined"
    assert report[:data][:repo] =~ "nonexistent_lei_test"
  end

  test "analyze with unsupported URI scheme returns error report" do
    {:ok, report} =
      AnalyzerModule.analyze(
        "ftp://example.com/some/repo",
        "scheme_test",
        %{}
      )

    assert report[:data][:error] =~ "Unable to analyze"
    assert report[:data][:risk] == "undetermined"
  end

  test "determine_risk_counts computes risk breakdown" do
    report = %{
      state: "complete",
      report: %{
        uuid: "test",
        repos: [
          %{data: %{risk: "critical"}},
          %{data: %{risk: "low"}},
          %{data: %{risk: "critical"}}
        ]
      },
      metadata: %{repo_count: 3}
    }

    result = AnalyzerModule.determine_risk_counts(report)
    assert result[:metadata][:risk_counts]["critical"] == 2
    assert result[:metadata][:risk_counts]["low"] == 1
  end

  test "determine_toplevel_risk assigns correct risk levels" do
    low_report = %{
      header: %{repo: "test"},
      data: %{
        results: %{
          contributor_risk: "low",
          commit_currency_risk: "low",
          functional_contributors_risk: "low",
          large_recent_commit_risk: "low",
          sbom_risk: "low"
        }
      }
    }

    result = AnalyzerModule.determine_toplevel_risk(low_report)
    assert result[:data][:risk] == "low"

    medium_report = put_in(low_report, [:data, :results, :sbom_risk], "medium")
    result = AnalyzerModule.determine_toplevel_risk(medium_report)
    assert result[:data][:risk] == "medium"

    high_report = put_in(low_report, [:data, :results, :contributor_risk], "high")
    result = AnalyzerModule.determine_toplevel_risk(high_report)
    assert result[:data][:risk] == "high"
  end

  test "get empty report" do
    start_time = DateTime.utc_now()
    uuid = UUID.uuid1()
    urls = ["https://github.com/kitplummer/xmpp4rails", "https://github.com/kitplummer/lita-cron"]
    empty_report = AnalyzerModule.create_empty_report(uuid, urls, start_time)

    assert uuid == empty_report[:uuid]
    assert "incomplete" == empty_report[:state]
  end
end
