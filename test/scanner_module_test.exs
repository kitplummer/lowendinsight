# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule ScannerModuleTest do
  use ExUnit.Case

  @fixtures_path Path.join([__DIR__, "fixtures"])

  describe "get_report/4" do
    test "returns error when project_types is empty" do
      start_time = DateTime.utc_now()
      reports = [hex: [], node_json: [], node_yarn: [], pypi: [], cargo: []]

      result = ScannerModule.get_report(start_time, 0, reports, %{})

      assert result == %{error: "No dependency manifest files were found"}
    end

    # Helper to create a minimal valid report structure
    defp make_report(repo_url, risk) do
      %{
        data: %{
          repo: repo_url,
          risk: risk,
          results: %{
            contributor_risk: risk,
            commit_currency_risk: risk,
            functional_contributors_risk: risk,
            large_recent_commit_risk: "low"
          }
        }
      }
    end

    test "generates report with single report type (hex)" do
      start_time = DateTime.utc_now()
      hex_report = [make_report("https://github.com/test/repo", "low")]
      reports = [hex: hex_report, node_json: [], node_yarn: [], pypi: [], cargo: []]
      project_types = %{mix: ["mix.exs"]}

      result = ScannerModule.get_report(start_time, 1, reports, project_types)

      assert result[:state] == :complete
      assert result[:metadata][:repo_count] == 1
      assert result[:metadata][:dependency_count] == 1
      assert result[:files] == [:hex]
      assert is_binary(result[:report][:uuid])
    end

    test "generates report with pypi reports" do
      start_time = DateTime.utc_now()
      pypi_report = [make_report("https://github.com/test/pyrepo", "medium")]
      reports = [hex: [], node_json: [], node_yarn: [], pypi: pypi_report, cargo: []]
      project_types = %{python: ["requirements.txt"]}

      result = ScannerModule.get_report(start_time, 2, reports, project_types)

      assert result[:state] == :complete
      assert result[:files] == [:pypi]
    end

    test "generates report with cargo reports" do
      start_time = DateTime.utc_now()
      cargo_report = [make_report("https://github.com/test/rustcrate", "low")]
      reports = [hex: [], node_json: [], node_yarn: [], pypi: [], cargo: cargo_report]
      project_types = %{cargo: ["Cargo.toml"]}

      result = ScannerModule.get_report(start_time, 3, reports, project_types)

      assert result[:state] == :complete
      assert result[:files] == [:cargo]
    end

    test "generates separate reports when both node_json and node_yarn are present" do
      start_time = DateTime.utc_now()
      json_report = [make_report("https://github.com/test/npm1", "low")]
      yarn_report = [make_report("https://github.com/test/npm2", "medium")]
      reports = [hex: [], node_json: json_report, node_yarn: yarn_report, pypi: [], cargo: []]
      project_types = %{node: ["package.json", "package-lock.json", "yarn.lock"]}

      result = ScannerModule.get_report(start_time, 2, reports, project_types)

      assert Map.has_key?(result, :scan_node_json)
      assert Map.has_key?(result, :scan_node_yarn)
      assert result[:scan_node_json][:state] == :complete
      assert result[:scan_node_yarn][:state] == :complete
    end

    test "includes timing metadata in report" do
      start_time = DateTime.utc_now()
      reports = [hex: [make_report("test", "low")], node_json: [], node_yarn: [], pypi: [], cargo: []]
      project_types = %{mix: ["mix.exs"]}

      result = ScannerModule.get_report(start_time, 1, reports, project_types)

      assert is_map(result[:metadata][:times])
      assert Map.has_key?(result[:metadata][:times], :start_time)
      assert Map.has_key?(result[:metadata][:times], :end_time)
      assert Map.has_key?(result[:metadata][:times], :duration)
    end

    test "combines multiple report types" do
      start_time = DateTime.utc_now()
      hex_report = [make_report("hex_repo", "low")]
      pypi_report = [make_report("pypi_repo", "medium")]
      cargo_report = [make_report("cargo_repo", "high")]
      reports = [hex: hex_report, node_json: [], node_yarn: [], pypi: pypi_report, cargo: cargo_report]
      project_types = %{mix: ["mix.exs"], python: ["requirements.txt"], cargo: ["Cargo.toml"]}

      result = ScannerModule.get_report(start_time, 5, reports, project_types)

      assert result[:state] == :complete
      assert result[:metadata][:repo_count] == 3
      assert :hex in result[:files]
      assert :pypi in result[:files]
      assert :cargo in result[:files]
    end
  end

  describe "get_report/4 additional paths" do
    defp make_report2(repo_url, risk) do
      %{
        data: %{
          repo: repo_url,
          risk: risk,
          results: %{
            contributor_risk: risk,
            commit_currency_risk: risk,
            functional_contributors_risk: risk,
            large_recent_commit_risk: "low"
          }
        }
      }
    end

    test "generates report with only node_yarn reports (no node_json)" do
      start_time = DateTime.utc_now()
      yarn_report = [make_report2("https://github.com/test/yarn-pkg", "low")]
      reports = [hex: [], node_json: [], node_yarn: yarn_report, pypi: [], cargo: []]
      project_types = %{node: ["package.json", "yarn.lock"]}

      result = ScannerModule.get_report(start_time, 1, reports, project_types)

      assert result[:state] == :complete
      assert result[:files] == [:node_yarn]
    end

    test "generates report with only node_json reports (no node_yarn)" do
      start_time = DateTime.utc_now()
      json_report = [make_report2("https://github.com/test/npm-pkg", "medium")]
      reports = [hex: [], node_json: json_report, node_yarn: [], pypi: [], cargo: []]
      project_types = %{node: ["package.json", "package-lock.json"]}

      result = ScannerModule.get_report(start_time, 1, reports, project_types)

      assert result[:state] == :complete
      assert result[:files] == [:node_json]
    end

    test "includes dependency_count in metadata" do
      start_time = DateTime.utc_now()
      hex_report = [make_report2("test", "low")]
      reports = [hex: hex_report, node_json: [], node_yarn: [], pypi: [], cargo: []]
      project_types = %{mix: ["mix.exs"]}

      result = ScannerModule.get_report(start_time, 42, reports, project_types)

      assert result[:metadata][:dependency_count] == 42
    end

    test "dual node reports include timing metadata" do
      start_time = DateTime.utc_now()
      json_report = [make_report2("npm1", "low")]
      yarn_report = [make_report2("yarn1", "low")]
      reports = [hex: [], node_json: json_report, node_yarn: yarn_report, pypi: [], cargo: []]
      project_types = %{node: ["package.json", "package-lock.json", "yarn.lock"]}

      result = ScannerModule.get_report(start_time, 2, reports, project_types)

      assert Map.has_key?(result, :metadata)
      assert Map.has_key?(result[:metadata], :times)
      assert Map.has_key?(result[:metadata][:times], :duration)
    end
  end

  describe "dependencies/1" do
    test "parses mix.lock and returns dependency JSON" do
      lockfile_path = Path.join(@fixtures_path, "lockfile")

      # Create temp directory with proper file name
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "scanner_deps_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      File.cp!(lockfile_path, Path.join(test_dir, "mix.lock"))

      result = ScannerModule.dependencies(test_dir)

      assert is_binary(result)
      decoded = Poison.decode!(result)
      # The result is a list of dependency maps
      assert is_list(decoded)
      assert length(decoded) > 0
      # Each dep should have certain keys
      first_dep = hd(decoded)
      assert Map.has_key?(first_dep, "name")
      assert Map.has_key?(first_dep, "version")

      File.rm_rf!(test_dir)
    end
  end
end
