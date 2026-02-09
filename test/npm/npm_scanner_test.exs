# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule NpmScannerTest do
  use ExUnit.Case

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])

  describe "scan/2 when node? is false" do
    test "returns empty lists and zero count" do
      {json_result, yarn_result, count} = Npm.Scanner.scan(false, %{})
      assert json_result == []
      assert yarn_result == []
      assert count == 0
    end
  end

  describe "scan/3 with fixtures" do
    test "returns error when no package.json is present" do
      project_types = %{node: ["some/path/to/yarn.lock"]}
      result = Npm.Scanner.scan(true, project_types, ".")
      assert result == {:error, "Must contain a package.json file"}
    end

    test "returns error with empty node paths" do
      project_types = %{node: []}
      result = Npm.Scanner.scan(true, project_types, ".")
      assert result == {:error, "Must contain a package.json file"}
    end
  end

  describe "scan/3 with package.json only" do
    @tag :network
    test "scans package.json when no lock files present" do
      package_json_path = Path.join(@fixtures_path, "packagejson")
      # Rename to match expected pattern
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "npm_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      File.cp!(package_json_path, Path.join(test_dir, "package.json"))

      project_types = %{node: [Path.join(test_dir, "package.json")]}

      # This test requires network access to query npm registry
      {result_map, yarn_map, deps_count} = Npm.Scanner.scan(true, project_types, ".")

      assert is_list(result_map)
      assert yarn_map == []
      assert deps_count == 1  # one devDependency in fixture

      File.rm_rf!(test_dir)
    end
  end

  describe "get_npm_repository/1" do
    # This is a private function, but we can test the module behavior
    # through integration tests with query_npm
  end
end
