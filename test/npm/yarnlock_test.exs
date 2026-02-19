# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule YarnlockTest do
  use ExUnit.Case

  test "extracts dependencies from yarn.lock" do
    {:ok, {lib_map, deps_count}} = Npm.Yarnlockfile.parse!(File.read!("./test/fixtures/yarnlock"))

    parsed_yarn = [{"assert-plus", "1.0.0"}]

    assert deps_count == 1
    assert parsed_yarn == lib_map
  end

  test "returns correct file_names" do
    assert Npm.Yarnlockfile.file_names() == ["yarn.lock"]
  end

  test "keeps higher version when duplicate packages exist" do
    # When the first occurrence has a higher version, the else branch keeps acc unchanged
    content = """
    # yarn lockfile v1

    lodash@^4.17.21:
      version "4.17.21"
      resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"

    lodash@^4.17.0:
      version "4.17.0"
      resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.0.tgz"
    """

    {:ok, {lib_map, deps_count}} = Npm.Yarnlockfile.parse!(content)
    assert deps_count == 1
    # Should keep the higher version (4.17.21)
    assert {"lodash", "4.17.21"} in lib_map
  end
end
