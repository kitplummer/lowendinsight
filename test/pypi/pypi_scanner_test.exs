# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule PypiScannerTest do
  use ExUnit.Case

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])

  describe "scan/2 when pypi? is false" do
    test "returns empty list and zero count" do
      {result, count} = Pypi.Scanner.scan(false, %{})
      assert result == []
      assert count == 0
    end

    test "returns empty with any project_types when pypi is false" do
      {result, count} = Pypi.Scanner.scan(false, %{python: ["some/path"]})
      assert result == []
      assert count == 0
    end
  end

  describe "scan/3 with fixtures" do
    test "returns error when no requirements.txt is present" do
      project_types = %{python: ["some/path/to/setup.py"]}
      result = Pypi.Scanner.scan(true, project_types, ".")
      assert result == {:error, "Must contain a requirements.txt file"}
    end

    test "returns error with empty python paths" do
      project_types = %{python: []}
      result = Pypi.Scanner.scan(true, project_types, ".")
      assert result == {:error, "Must contain a requirements.txt file"}
    end
  end

  describe "scan/3 with requirements.txt" do
    @tag :network
    test "scans requirements.txt and queries pypi" do
      requirements_path = Path.join(@fixtures_path, "requirementstxt")
      # Rename to match expected pattern
      tmp_dir = System.tmp_dir!()
      test_dir = Path.join(tmp_dir, "pypi_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      File.cp!(requirements_path, Path.join(test_dir, "requirements.txt"))

      project_types = %{python: [Path.join(test_dir, "requirements.txt")]}

      # This test requires network access to query pypi
      {result_map, deps_count} = Pypi.Scanner.scan(true, project_types, ".")

      assert is_list(result_map)
      assert deps_count == 2  # furl and quokka in fixture

      File.rm_rf!(test_dir)
    end
  end
end
