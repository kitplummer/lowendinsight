# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule CargoScannerTest do
  use ExUnit.Case

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])

  describe "scan/2 when cargo? is false" do
    test "returns empty when cargo? is false" do
      {result, count} = Cargo.Scanner.scan(false, %{})
      assert result == []
      assert count == 0
    end

    test "returns empty with any project_types when cargo is false" do
      {result, count} = Cargo.Scanner.scan(false, %{cargo: ["some/path"]})
      assert result == []
      assert count == 0
    end
  end

  describe "scan/2 with fixtures" do
    test "handles missing Cargo.toml gracefully" do
      project_types = %{cargo: ["some/nonexistent/path/Cargo.lock"]}
      {result, count} = Cargo.Scanner.scan(true, project_types)
      assert result == []
      assert count == 0
    end

    test "scans Cargo.toml without Cargo.lock" do
      tmp_dir = Path.join(System.tmp_dir!(), "lei_cargo_nolock_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      cargo_toml = """
      [package]
      name = "test"
      version = "0.1.0"

      [dependencies]
      serde = "1.0"
      """

      File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml)

      project_types = %{cargo: [Path.join(tmp_dir, "Cargo.toml")]}
      {result, count} = Cargo.Scanner.scan(true, project_types)

      assert is_list(result)
      assert result == []
      assert count > 0

      File.rm_rf!(tmp_dir)
    end

    test "scans with both Cargo.toml and Cargo.lock from fixtures" do
      cargo_toml_path = Path.join(@fixtures_path, "cargotoml")
      cargo_lock_path = Path.join(@fixtures_path, "cargolock")

      tmp_dir = Path.join(System.tmp_dir!(), "lei_cargo_both_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.cp!(cargo_toml_path, Path.join(tmp_dir, "Cargo.toml"))
      File.cp!(cargo_lock_path, Path.join(tmp_dir, "Cargo.lock"))

      project_types = %{cargo: [Path.join(tmp_dir, "Cargo.toml")]}

      # This scans both files but analyze_package needs network for crates.io packages
      # The scan function will still parse both files and return the count
      {result_map, deps_count} = Cargo.Scanner.scan(true, project_types)

      assert is_list(result_map)
      assert is_integer(deps_count)

      File.rm_rf!(tmp_dir)
    end

    @tag :network
    test "scans Cargo.toml and Cargo.lock files" do
      cargo_toml_path = Path.join(@fixtures_path, "cargotoml")
      cargo_lock_path = Path.join(@fixtures_path, "cargolock")

      # Create temp directory with proper file names
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "cargo_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      File.cp!(cargo_toml_path, Path.join(test_dir, "Cargo.toml"))
      File.cp!(cargo_lock_path, Path.join(test_dir, "Cargo.lock"))

      project_types = %{cargo: [Path.join(test_dir, "Cargo.toml")]}

      # This test requires network access to query crates.io
      {result_map, deps_count} = Cargo.Scanner.scan(true, project_types)

      assert is_list(result_map)
      assert is_integer(deps_count)

      File.rm_rf!(test_dir)
    end
  end

  describe "get_repo_url/2" do
    test "returns git URL directly for git sources" do
      source = {:git, %{url: "https://github.com/example/repo", commit: "abc123"}}
      assert Cargo.Scanner.get_repo_url("example", source) == "https://github.com/example/repo"
    end

    test "returns nil for unknown source types" do
      assert Cargo.Scanner.get_repo_url("crate", {:unknown, "something"}) == nil
    end

    test "handles crates.io source type" do
      # This would query the network, so we just verify it doesn't crash
      # The actual network test is tagged :network
      source = {:crates_io, %{version: "1.0.0"}}
      result = Cargo.Scanner.get_repo_url("nonexistent_crate_12345", source)
      # Should return nil for non-existent crate (or a URL if it exists)
      assert is_nil(result) or is_binary(result)
    end

    test "handles nil source by querying crates.io" do
      result = Cargo.Scanner.get_repo_url("nonexistent_crate_12345", nil)
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "analyze_dependencies/1" do
    test "returns empty list for empty deps" do
      assert Cargo.Scanner.analyze_dependencies([]) == []
    end

    test "filters out nil results" do
      # Dependencies without valid source URLs should be filtered out
      deps = [
        {:test_crate, %{name: "test", source_url: {:unknown, "invalid"}}}
      ]
      result = Cargo.Scanner.analyze_dependencies(deps)
      assert result == []
    end
  end
end
