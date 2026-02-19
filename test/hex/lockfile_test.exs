# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LockfileTest do
  use ExUnit.Case

  test "extracts dependencies from mix.lock" do
    {:ok, {lib_map, deps_count}} = Hex.Lockfile.parse!(File.read!("./test/fixtures/lockfile"))

    parsed_lockfile = [
      {:hex, :cowboy, "1.0.4"},
      {:hex, :cowlib, "1.0.2"},
      {:git, "https://github.com/tim/erlang-oauth.git",
       "bd19896e31125f99ff45bb5850b1c0e74b996743"},
      {:hex, :plug, "1.1.6"},
      {:hex, :poison, "2.1.0"},
      {:hex, :ranch, "1.2.1"}
    ]

    assert deps_count == 6
    assert parsed_lockfile == lib_map
  end

  test "file_names returns correct file name" do
    assert Hex.Lockfile.file_names() == ["mix.lock"]
  end

  test "parse! with full extraction flag" do
    content = File.read!("./test/fixtures/lockfile")
    result = Hex.Lockfile.parse!(content, true)
    assert is_list(result)
  end

  test "parses the actual project mix.lock" do
    {:ok, {lib_map, deps_count}} = Hex.Lockfile.parse!(File.read!("./mix.lock"))
    assert deps_count > 0
    assert is_list(lib_map)
  end

  test "parses 4-element hex entry" do
    content = ~s(%{"test4": {:hex, :test4, "1.0.0", "hash123"}})
    {:ok, {lib_map, deps_count}} = Hex.Lockfile.parse!(content)
    assert deps_count == 1
    assert [{:hex, :test4, "1.0.0"}] == lib_map
  end

  test "parses 7-element hex entry" do
    content = ~s(%{"test7": {:hex, :test7, "2.0.0", "hash", [:mix], [], "hexpm"}})
    {:ok, {lib_map, deps_count}} = Hex.Lockfile.parse!(content)
    assert deps_count == 1
    assert [{:hex, :test7, "2.0.0"}] == lib_map
  end

  test "parses mix of 3, 4, 6, 7, and 8 element entries" do
    content = ~s(%{
      "dep3": {:git, "https://github.com/user/repo.git", "abc123"},
      "dep4": {:hex, :dep4, "1.0.0", "hash"},
      "dep6": {:hex, :dep6, "2.0.0", "hash", [:mix], []},
      "dep7": {:hex, :dep7, "3.0.0", "hash", [:mix], [], "hexpm"},
      "dep8": {:hex, :dep8, "4.0.0", "hash", [:mix], [], "hexpm", "checksum"}
    })
    {:ok, {lib_map, deps_count}} = Hex.Lockfile.parse!(content)
    assert deps_count == 5
    names = Enum.map(lib_map, fn {_, name, _} -> name end)
    assert :dep3 in names or "https://github.com/user/repo.git" in Enum.map(lib_map, fn {_, n, _} -> n end)
    assert :dep4 in names
    assert :dep6 in names
    assert :dep7 in names
    assert :dep8 in names
  end
end
