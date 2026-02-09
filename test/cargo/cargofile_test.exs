# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule CargofileTest do
  use ExUnit.Case

  test "extracts dependencies from Cargo.toml" do
    {:ok, {deps, deps_count}} =
      Cargo.Cargofile.parse!(File.read!("./test/fixtures/cargotoml"))

    assert deps_count == 7

    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :tokio) == "1.28"
    assert Keyword.get(deps, :reqwest) == "0.11"
    assert Keyword.get(deps, :clap) == "4.3"
    assert Keyword.get(deps, :assert_cmd) == "2.0"
    assert Keyword.get(deps, :predicates) == "3.0"
    assert Keyword.get(deps, :cc) == "1.0"
  end

  test "returns correct file_names" do
    assert Cargo.Cargofile.file_names() == ["Cargo.toml"]
  end

  test "handles Cargo.toml with only dependencies" do
    content = """
    [package]
    name = "simple"
    version = "0.1.0"

    [dependencies]
    serde = "1.0"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 1
    assert Keyword.get(deps, :serde) == "1.0"
  end

  test "handles Cargo.toml with no dependencies" do
    content = """
    [package]
    name = "bare"
    version = "0.1.0"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 0
    assert deps == []
  end

  test "handles build-dependencies section" do
    content = """
    [package]
    name = "with-build"
    version = "0.1.0"

    [dependencies]
    serde = "1.0"

    [build-dependencies]
    cc = "1.0"
    pkg-config = "0.3"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 3
    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :cc) == "1.0"
    assert Keyword.get(deps, :"pkg-config") == "0.3"
  end

  test "handles workspace.dependencies section" do
    content = """
    [workspace.dependencies]
    serde = { version = "1.0", features = ["derive"] }
    tokio = "1.28"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 2
    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :tokio) == "1.28"
  end

  test "handles git dependencies" do
    content = """
    [dependencies]
    my-lib = { git = "https://github.com/user/my-lib", version = "0.5" }
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 1

    dep = Keyword.get(deps, :"my-lib")
    assert dep == %{git: "https://github.com/user/my-lib", version: "0.5"}
  end

  test "handles path dependencies" do
    content = """
    [dependencies]
    my-local = { path = "../my-local" }
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 1

    dep = Keyword.get(deps, :"my-local")
    assert dep == %{path: "../my-local", version: ""}
  end

  test "handles comments within dependency sections" do
    content = """
    [dependencies]
    # Main serialization library
    serde = "1.0"
    # Async runtime
    tokio = "1.28"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 2
    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :tokio) == "1.28"
  end

  test "merges deps from all sections" do
    content = """
    [dependencies]
    serde = "1.0"

    [dev-dependencies]
    assert_cmd = "2.0"

    [build-dependencies]
    cc = "1.0"
    """

    {:ok, {deps, deps_count}} = Cargo.Cargofile.parse!(content)
    assert deps_count == 3
    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :assert_cmd) == "2.0"
    assert Keyword.get(deps, :cc) == "1.0"
  end
end
