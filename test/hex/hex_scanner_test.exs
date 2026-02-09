# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule HexScannerTest do
  use ExUnit.Case

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])

  describe "scan/2 when mix? is false" do
    test "returns empty list and zero count" do
      {result, count} = Hex.Scanner.scan(false, %{})
      assert result == []
      assert count == 0
    end

    test "returns empty with any project_types when mix is false" do
      {result, count} = Hex.Scanner.scan(false, %{mix: ["some/path"]})
      assert result == []
      assert count == 0
    end
  end

  describe "scan/2 with fixtures" do
    @tag :network
    test "scans mix.exs and mix.lock files" do
      mixfile_path = Path.join(@fixtures_path, "mixfile")
      lockfile_path = Path.join(@fixtures_path, "lockfile")

      # Create temp directory with proper file names
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "hex_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      File.cp!(mixfile_path, Path.join(test_dir, "mix.exs"))
      File.cp!(lockfile_path, Path.join(test_dir, "mix.lock"))

      project_types = %{mix: [Path.join(test_dir, "mix.exs"), Path.join(test_dir, "mix.lock")]}

      # This test requires network access to query hex.pm
      {result_map, deps_count} = Hex.Scanner.scan(true, project_types)

      assert is_list(result_map)
      assert deps_count == 3  # oauth, poison, plug in fixture

      File.rm_rf!(test_dir)
    end
  end
end
