# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.SbomTaskTest do
  use ExUnit.Case, async: false

  describe "run/1 error paths" do
    test "reports usage error when no URL is provided" do
      Mix.Tasks.Lei.Sbom.run([])
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage"
    end

    test "reports error for unknown format" do
      Mix.Tasks.Lei.Sbom.run([
        "https://github.com/kitplummer/xmpp4rails",
        "--format",
        "invalid_format"
      ])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Unknown format"
    end
  end

  describe "run/1 with local repo (no network)" do
    test "generates CycloneDX SBOM from local file:// repo" do
      {:ok, cwd} = File.cwd()
      Mix.Tasks.Lei.Sbom.run(["file:///#{cwd}"])
      assert_received {:mix_shell, :info, [json]}
      decoded = Poison.decode!(json)
      assert decoded["bomFormat"] == "CycloneDX"
      assert decoded["specVersion"] == "1.4"
    end

    test "generates SPDX SBOM from local file:// repo" do
      {:ok, cwd} = File.cwd()
      Mix.Tasks.Lei.Sbom.run(["file:///#{cwd}", "--format", "spdx"])
      assert_received {:mix_shell, :info, [json]}
      decoded = Poison.decode!(json)
      assert decoded["spdxVersion"] == "SPDX-2.3"
    end

    test "writes SBOM to output file from local file:// repo" do
      {:ok, cwd} = File.cwd()
      output = Path.join(System.tmp_dir!(), "lei-test-sbom-local-#{:erlang.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(output) end)

      Mix.Tasks.Lei.Sbom.run(["file:///#{cwd}", "--output", output])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "SBOM written to"
      assert File.exists?(output)
    end
  end

  describe "run/1 with real repository" do
    @describetag :network
    @describetag :long

    test "generates CycloneDX SBOM" do
      Mix.Tasks.Lei.Sbom.run(["https://github.com/kitplummer/xmpp4rails"])
      assert_received {:mix_shell, :info, [json]}
      decoded = Poison.decode!(json)
      assert decoded != nil
    end

    test "generates SPDX SBOM" do
      Mix.Tasks.Lei.Sbom.run([
        "https://github.com/kitplummer/xmpp4rails",
        "--format",
        "spdx"
      ])

      assert_received {:mix_shell, :info, [json]}
      decoded = Poison.decode!(json)
      assert decoded != nil
    end

    test "writes SBOM to output file" do
      output = Path.join(System.tmp_dir!(), "lei-test-sbom-#{:rand.uniform(100_000)}.json")
      on_exit(fn -> File.rm(output) end)

      Mix.Tasks.Lei.Sbom.run([
        "https://github.com/kitplummer/xmpp4rails",
        "--output",
        output
      ])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "SBOM written to"
      assert File.exists?(output)
    end
  end
end
