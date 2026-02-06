# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule CargoScannerTest do
  use ExUnit.Case

  describe "scan/2" do
    test "returns empty when cargo? is false" do
      {result, count} = Cargo.Scanner.scan(false, %{})
      assert result == []
      assert count == 0
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
  end

  describe "analyze_dependencies/1" do
    test "returns empty list for empty deps" do
      assert Cargo.Scanner.analyze_dependencies([]) == []
    end
  end
end
