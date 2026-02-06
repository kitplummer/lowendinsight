# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule CargofileTest do
  use ExUnit.Case

  test "extracts dependencies from Cargo.toml" do
    {:ok, {deps, deps_count}} =
      Cargo.Cargofile.parse!(File.read!("./test/fixtures/cargotoml"))

    assert deps_count == 6

    assert Keyword.get(deps, :serde) == "1.0"
    assert Keyword.get(deps, :tokio) == "1.28"
    assert Keyword.get(deps, :reqwest) == "0.11"
    assert Keyword.get(deps, :clap) == "4.3"
    assert Keyword.get(deps, :assert_cmd) == "2.0"
    assert Keyword.get(deps, :predicates) == "3.0"
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
end
