defmodule Lowendinsight.MixTaskArgsTest do
  @moduledoc """
  The mix tasks refuse bad arguments instead of doing something surprising.

  Checked on 2026-09-16, before this:

    * `mix lei.analyze` with no arguments printed a "complete" report of zero
      repositories -- a success-shaped answer to a mistake;
    * `mix lei.analyze --format bogus` analysed `--format` and `bogus` as
      repository URLs and reported them as undetermined risk;
    * `mix lei.sarif . --bogus` crashed with a stack trace;
    * `mix lei.sbom <url> --format typo` cloned the repository first and
      complained afterwards (fixed in #203).
  """
  use ExUnit.Case, async: true

  describe "lei.analyze" do
    test "no url is a usage error, not an empty report" do
      assert {:error, msg} = Mix.Tasks.Lei.Analyze.parse_args([])
      assert msg =~ "Usage"
    end

    test "a flag is not a repository" do
      assert {:error, msg} = Mix.Tasks.Lei.Analyze.parse_args(["--format", "bogus"])
      assert msg =~ "--format"
    end

    test "urls are passed through, in order" do
      urls = ["https://github.com/o/a", "https://github.com/o/b"]
      assert {:ok, ^urls} = Mix.Tasks.Lei.Analyze.parse_args(urls)
    end
  end

  describe "lei.sarif" do
    test "an unknown switch is refused, not a crash" do
      assert {:error, msg} = Mix.Tasks.Lei.Sarif.parse_args([".", "--bogus"])
      assert msg =~ "--bogus"
    end

    test "defaults to the current directory" do
      assert {:ok, %{path: ".", output: nil}} = Mix.Tasks.Lei.Sarif.parse_args([])
    end

    test "takes a path and an output file" do
      assert {:ok, %{path: "/tmp", output: "out.sarif"}} =
               Mix.Tasks.Lei.Sarif.parse_args(["/tmp", "-o", "out.sarif"])
    end
  end

  describe "lei.sbom" do
    test "still refuses an unknown format before cloning (#203)" do
      assert {:error, msg} =
               Mix.Tasks.Lei.Sbom.parse_args(["https://github.com/o/r", "--format", "x"])

      assert msg =~ "Unknown format"
    end

    test "an unknown switch is refused" do
      assert {:error, msg} = Mix.Tasks.Lei.Sbom.parse_args(["https://github.com/o/r", "--bogus"])
      assert msg =~ "--bogus"
    end
  end
end
