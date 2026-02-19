# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.SarifTaskTest do
  use ExUnit.Case, async: false

  @minimal_mix_exs """
  defmodule SarifMinimal.MixProject do
    use Mix.Project

    def project do
      [app: :sarif_minimal, version: "0.1.0", deps: deps()]
    end

    defp deps do
      []
    end
  end
  """

  describe "run/1 error paths" do
    test "reports error for invalid path" do
      Mix.Tasks.Lei.Sarif.run(["nonexistent_path_12345"])
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Invalid path"
    end
  end

  describe "run/1 with minimal project (no network)" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "lei_sarif_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "mix.exs"), @minimal_mix_exs)
      File.write!(Path.join(tmp_dir, "mix.lock"), "%{}")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "generates SARIF for minimal project", %{tmp_dir: tmp_dir} do
      Mix.Tasks.Lei.Sarif.run([tmp_dir])
      assert_received {:mix_shell, :info, [sarif_json]}
      decoded = Poison.decode!(sarif_json)
      assert decoded["$schema"] =~ "sarif"
      assert decoded["version"] == "2.1.0"
    end

    test "writes SARIF to output file", %{tmp_dir: tmp_dir} do
      output = Path.join(System.tmp_dir!(), "lei-sarif-output-#{:erlang.unique_integer([:positive])}.sarif")
      on_exit(fn -> File.rm(output) end)

      Mix.Tasks.Lei.Sarif.run([tmp_dir, "--output", output])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "SARIF written to"
      assert File.exists?(output)
    end
  end

  describe "run/1 with no args uses default path" do
    test "uses current directory as default path" do
      # Running with no args uses "." as default path
      # Since we're in the project root which exists, it should work
      Mix.Tasks.Lei.Sarif.run([])
      assert_received {:mix_shell, :info, [sarif_json]}
      decoded = Poison.decode!(sarif_json)
      assert decoded["version"] == "2.1.0"
    end
  end

  describe "run/1 with local project" do
    @describetag :network
    @describetag :long

    test "generates SARIF for current directory" do
      Mix.Tasks.Lei.Sarif.run(["."])
      assert_received {:mix_shell, :info, [sarif_json]}
      decoded = Poison.decode!(sarif_json)
      assert decoded["$schema"] != nil || decoded["version"] != nil
    end

    test "writes SARIF to output file" do
      output = Path.join(System.tmp_dir!(), "lei-test-sarif-#{:rand.uniform(100_000)}.sarif")

      on_exit(fn -> File.rm(output) end)

      Mix.Tasks.Lei.Sarif.run([".", "--output", output])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "SARIF written to"
      assert File.exists?(output)
    end
  end
end
