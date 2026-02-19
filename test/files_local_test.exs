# Copyright (C) 2022 by Kit Plummer
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule FilesLocalTest do
  use ExUnit.Case, async: false

  test "analyze_files works on current directory" do
    result = Lowendinsight.Files.analyze_files(".")
    assert is_map(result)
    assert is_list(result.binary_files)
    assert is_integer(result.binary_files_count)
    assert is_integer(result.total_file_count)
    assert is_boolean(result.has_readme)
    assert is_boolean(result.has_license)
    assert is_boolean(result.has_contributing)
  end

  test "find_binary_files returns list for current directory" do
    result = Lowendinsight.Files.find_binary_files(".")
    assert is_list(result.binary_files)
    assert is_integer(result.binary_files_count)
  end

  test "has_readme? returns true for project root" do
    assert %{has_readme: true} = Lowendinsight.Files.has_readme?(".")
  end

  test "has_license? returns true for project root" do
    assert %{has_license: true} = Lowendinsight.Files.has_license?(".")
  end

  test "get_total_file_count returns positive count for project" do
    result = Lowendinsight.Files.get_total_file_count(".")
    assert result.total_file_count > 0
  end
end
