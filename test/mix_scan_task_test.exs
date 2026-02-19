# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.ScanTaskTest do
  use ExUnit.Case, async: false

  @minimal_mix_exs """
  defmodule ScanMinimal.MixProject do
    use Mix.Project

    def project do
      [app: :scan_minimal, version: "0.1.0", deps: deps()]
    end

    defp deps do
      []
    end
  end
  """

  describe "run/1 error paths" do
    test "reports invalid path message for nonexistent directory" do
      Mix.Tasks.Lei.Scan.run(["/nonexistent/path/lei_test_12345"])
      assert_received {:mix_shell, :info, ["Invalid path"]}
    end
  end

  describe "run/1 with minimal project (no network)" do
    setup do
      # Initialize a git repo in a temp dir with minimal mix project
      tmp_dir = Path.join(System.tmp_dir!(), "lei_scan_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "mix.exs"), @minimal_mix_exs)
      File.write!(Path.join(tmp_dir, "mix.lock"), "%{}")

      # Initialize git repo (required by GitModule.get_repo)
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["-c", "user.email=test@test.com", "-c", "user.name=Test",
                          "commit", "-m", "init"], cd: tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "scans a minimal project directory", %{tmp_dir: tmp_dir} do
      Mix.Tasks.Lei.Scan.run([tmp_dir])
      assert_received {:mix_shell, :info, [report]}
      decoded = Poison.decode!(report)
      assert decoded["state"] == "complete"
      assert decoded["metadata"]["dependency_count"] == 0
    end
  end

  describe "run/1 with local project" do
    @describetag :network
    @describetag :long

    test "scans current directory with no args" do
      Mix.Tasks.Lei.Scan.run([])
      assert_received {:mix_shell, :info, [report]}
      decoded = Poison.decode!(report)
      assert decoded["state"] == "complete" || Map.has_key?(decoded, "error")
    end

    test "scans explicit path" do
      Mix.Tasks.Lei.Scan.run(["."])
      assert_received {:mix_shell, :info, [report]}
      decoded = Poison.decode!(report)
      assert decoded != nil
    end
  end
end
