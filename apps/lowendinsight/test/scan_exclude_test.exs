Mix.shell(Mix.Shell.Process)

defmodule ScanExcludeTest do
  @moduledoc """
  A scan can leave a directory out (`mix lei.sarif --exclude DIR`).

  This repository's own SARIF scan went from about eleven minutes to between
  one and two hours on 2026-10-27, and runs piled up behind each other. The VS
  Code extension's package-lock.json had become tracked (#331), and the scan
  analysed every package in it: 341 repositories, every one a dev-only build
  tool of an extension that has no runtime dependencies at all. There was no
  way to say "not that directory".

  Leaving something out of a supply-chain scan is a decision that should be
  visible, so what was excluded is printed, and an exclusion naming a
  directory that does not exist is refused: a typo, or a directory since
  renamed, would otherwise quietly mean something else.
  """
  use ExUnit.Case, async: false

  # The shape mix_sarif_task_test.exs uses: Hex.Mixfile reads deps/0's body.
  @mix_exs """
  defmodule ScanExclude.MixProject do
    use Mix.Project

    def project do
      [app: :scan_exclude, version: "0.1.0", deps: deps()]
    end

    defp deps do
      []
    end
  end
  """

  # A lockfile v3 naming a package: scanning it would look the package up in
  # the npm registry and clone its repository.
  @package_lock ~s({"name": "ext", "lockfileVersion": 3, "packages": {"": {"name": "ext"},
    "node_modules/left-pad": {"version": "1.3.0", "dev": true}}})

  setup do
    dir = Path.join(System.tmp_dir!(), "scan_exclude_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "editor/ext"))
    File.write!(Path.join(dir, "mix.exs"), @mix_exs)
    File.write!(Path.join(dir, "mix.lock"), "%{}")
    File.write!(Path.join(dir, "editor/ext/package.json"), ~s({"name": "ext"}))
    File.write!(Path.join(dir, "editor/ext/package-lock.json"), @package_lock)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "ProjectIdent" do
    test "finds a manifest in a subdirectory", %{dir: dir} do
      assert Map.has_key?(ProjectIdent.get_project_types_identified(dir), :node)
    end

    test "leaves out manifests under an excluded directory", %{dir: dir} do
      found = ProjectIdent.get_project_types_identified(dir, exclude: ["editor/ext"])

      refute Map.has_key?(found, :node), "an excluded directory's manifests were scanned"
      assert Map.has_key?(found, :mix), "excluding one directory removed another's manifests"
    end

    test "an exclusion is a directory, not a prefix of a name", %{dir: dir} do
      # "editor/e" must not exclude "editor/ext".
      found = ProjectIdent.get_project_types_identified(dir, exclude: ["editor/e"])
      assert Map.has_key?(found, :node)
    end
  end

  describe "mix lei.sarif --exclude" do
    test "is parsed, repeatably" do
      assert {:ok, %{exclude: ["a", "b/c"]}} =
               Mix.Tasks.Lei.Sarif.parse_args([".", "--exclude", "a", "--exclude", "b/c"])

      assert {:ok, %{exclude: []}} = Mix.Tasks.Lei.Sarif.parse_args(["."])
    end

    test "scans without the excluded directory, and says what it left out", %{dir: dir} do
      out = Path.join(dir, "out.sarif")

      Mix.Tasks.Lei.Sarif.run([dir, "--exclude", "editor/ext", "--output", out])

      assert File.exists?(out), "no SARIF was written"
      assert_received {:mix_shell, :info, [excluded]}
      assert excluded =~ "editor/ext/package-lock.json"
      assert Poison.decode!(File.read!(out))["version"] == "2.1.0"
    end

    test "refuses an exclusion that names no directory", %{dir: dir} do
      out = Path.join(dir, "out.sarif")

      Mix.Tasks.Lei.Sarif.run([dir, "--exclude", "editor/renamed", "--output", out])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "editor/renamed"
      refute File.exists?(out), "scanned anyway, with an exclusion that excluded nothing"
    end
  end
end
