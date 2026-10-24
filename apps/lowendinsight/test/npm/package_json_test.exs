# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule PackageJSONTest do
  use ExUnit.Case

  test "extracts dependencies from package.json" do
    {:ok, {lib_map, deps_count}} =
      Npm.Packagefile.parse!(File.read!("./test/fixtures/packagejson"))

    parsed_package_json = [
      {"simple-npm-package", "3.0.8"}
    ]

    assert deps_count == 1
    assert parsed_package_json == lib_map
  end

  test "extracts dependencies from package-lock.json" do
    {:ok, {lib_map, deps_count}} =
      Npm.Packagefile.parse!(File.read!("./test/fixtures/package-lockjson"))

    parsed_package_lock_json = [
      {"combined-stream", "1.0.8"}
    ]

    assert deps_count == 1
    assert parsed_package_lock_json == lib_map
  end

  test "returns correct file_names" do
    assert Npm.Packagefile.file_names() == ["package.json", "package-lock.json"]
  end

  test "handles package with devDependencies only" do
    content = ~s({"devDependencies": {"jest": "^26.0.0"}})
    {:ok, {lib_map, deps_count}} = Npm.Packagefile.parse!(content)

    assert deps_count == 1
    assert [{"jest", "26.0.0"}] == lib_map
  end

  test "handles package with both dependencies and devDependencies" do
    content = ~s({"dependencies": {"express": "^4.17.1"}, "devDependencies": {"jest": "^26.0.0"}})
    {:ok, {lib_map, deps_count}} = Npm.Packagefile.parse!(content)

    assert deps_count == 2
  end

  test "handles version with tilde prefix" do
    content = ~s({"dependencies": {"lodash": "~4.17.21"}})
    {:ok, {lib_map, deps_count}} = Npm.Packagefile.parse!(content)

    assert deps_count == 1
    assert [{"lodash", "4.17.21"}] == lib_map
  end

  test "handles exact version without prefix" do
    content = ~s({"dependencies": {"lodash": "4.17.21"}})
    {:ok, {lib_map, deps_count}} = Npm.Packagefile.parse!(content)

    assert deps_count == 1
    assert [{"lodash", "4.17.21"}] == lib_map
  end

  # npm 7+ writes lockfileVersion 3: dependencies are under "packages", keyed by
  # install path, and there is no top-level "dependencies". The parser had no
  # clause for it and raised, which crashed `mix lei.sarif` on every scheduled
  # run of lei_sarif_scan -- hidden by continue-on-error, so the workflow stayed
  # green while uploading nothing.
  test "extracts top-level dependencies from a lockfileVersion 3 package-lock.json" do
    content = ~s({
      "name": "app", "lockfileVersion": 3,
      "packages": {
        "": {"name": "app", "dependencies": {"express": "^4.17.1"}},
        "node_modules/express": {"version": "4.21.2"},
        "node_modules/@babel/core": {"version": "7.26.0", "dev": true},
        "node_modules/express/node_modules/debug": {"version": "2.6.9"},
        "node_modules/local-thing": {"resolved": "../local-thing", "link": true}
      }
    })

    {:ok, {lib_map, deps_count}} = Npm.Packagefile.parse!(content)

    assert deps_count == 2
    assert Enum.sort(lib_map) == [{"@babel/core", "7.26.0"}, {"express", "4.21.2"}]
  end

  test "a manifest with no dependencies has none, rather than raising" do
    assert {:ok, {[], 0}} = Npm.Packagefile.parse!(~s({"name": "empty", "version": "1.0.0"}))
  end
end
