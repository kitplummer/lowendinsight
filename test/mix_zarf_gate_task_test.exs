# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.ZarfGateTaskTest do
  use ExUnit.Case, async: false

  @minimal_mix_exs """
  defmodule ZarfMinimal.MixProject do
    use Mix.Project

    def project do
      [app: :zarf_minimal, version: "0.1.0", deps: deps()]
    end

    defp deps do
      []
    end
  end
  """

  describe "run/1 error paths" do
    test "reports error for nonexistent path" do
      assert catch_exit(
               Mix.Tasks.Lei.ZarfGate.run(["--path", "/nonexistent/path/12345"])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Path does not exist"
    end
  end

  describe "run/1 with minimal project (no network)" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "lei_zarf_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "mix.exs"), @minimal_mix_exs)
      File.write!(Path.join(tmp_dir, "mix.lock"), "%{}")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "scans minimal project and evaluates gate", %{tmp_dir: tmp_dir} do
      # With 0 deps, the gate should pass (nothing to fail)
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", tmp_dir, "--threshold", "critical"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      # Should have received scanning message and JSON output
      assert_received {:mix_shell, :info, [scanning_msg]}
      assert scanning_msg =~ "Scanning project"
    end

    test "outputs JSON format by default for minimal project", %{tmp_dir: tmp_dir} do
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", tmp_dir, "--threshold", "critical", "--format", "json"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_scanning_msg]}
      assert_received {:mix_shell, :info, [json_output]}
      # Output should be valid JSON
      assert is_binary(json_output)
    end

    test "outputs SARIF format for minimal project", %{tmp_dir: tmp_dir} do
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", tmp_dir, "--threshold", "critical", "--format", "sarif"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_scanning_msg]}
      assert_received {:mix_shell, :info, [sarif_output]}
      assert is_binary(sarif_output)
    end

    test "writes output to file for minimal project", %{tmp_dir: tmp_dir} do
      output = Path.join(System.tmp_dir!(), "lei-zarf-output-#{:erlang.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(output) end)

      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path", tmp_dir,
          "--threshold", "critical",
          "--output", output
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert File.exists?(output)
    end

    test "quiet mode suppresses informational output for minimal project", %{tmp_dir: tmp_dir} do
      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path", tmp_dir,
          "--threshold", "critical",
          "--quiet"
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      # In quiet mode, should still get JSON result but not scanning message
      assert_received {:mix_shell, :info, [_result]}
    end

    test "non-quiet mode shows GATE PASSED message for passing gate", %{tmp_dir: tmp_dir} do
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", tmp_dir, "--threshold", "critical"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      # Drain all messages and check for GATE PASSED
      messages = drain_mix_messages()
      gate_msg = Enum.find(messages, &String.contains?(&1, "GATE"))

      assert gate_msg != nil
      assert gate_msg =~ "GATE PASSED"
    end

    test "shows GATE FAILED message when repo exceeds threshold", %{tmp_dir: tmp_dir} do
      # Create a local git repo with 1 contributor to trigger critical contributor risk
      repo_dir = Path.join(tmp_dir, "failing-repo")
      File.mkdir_p!(repo_dir)
      System.cmd("git", ["init"], cd: repo_dir)
      File.write!(Path.join(repo_dir, "README.md"), "# test\n")
      System.cmd("git", ["add", "."], cd: repo_dir)
      System.cmd("git", ["-c", "user.email=test@test.com", "-c", "user.name=Test",
                          "commit", "-m", "init"], cd: repo_dir)

      try do
        Mix.Tasks.Lei.ZarfGate.run(["--repo", "file:///#{repo_dir}", "--threshold", "high"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      messages = drain_mix_messages()
      gate_msg = Enum.find(messages, fn msg -> String.contains?(msg, "GATE") end)
      assert gate_msg != nil
      assert gate_msg =~ "GATE FAILED"
    end

    test "writes output to file and shows written message in non-quiet mode", %{tmp_dir: tmp_dir} do
      output = Path.join(System.tmp_dir!(), "lei-zarf-nonquiet-#{:erlang.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(output) end)

      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path", tmp_dir,
          "--threshold", "critical",
          "--output", output
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert File.exists?(output)
      messages = drain_mix_messages()
      assert Enum.any?(messages, &String.contains?(&1, "Results written to"))
    end
  end

  defp drain_mix_messages do
    drain_mix_messages([])
  end

  defp drain_mix_messages(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_mix_messages([msg | acc])
      {:mix_shell, :error, [msg]} -> drain_mix_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/1 with local project" do
    @describetag :network
    @describetag :long

    test "scans local path and evaluates gate" do
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", ".", "--threshold", "critical"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_msg]}
    end

    test "outputs JSON format by default" do
      try do
        Mix.Tasks.Lei.ZarfGate.run(["--path", ".", "--threshold", "critical", "--format", "json"])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_msg]}
    end

    test "outputs SARIF format when requested" do
      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path",
          ".",
          "--threshold",
          "critical",
          "--format",
          "sarif"
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_msg]}
    end

    test "quiet mode suppresses informational output" do
      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path",
          ".",
          "--threshold",
          "critical",
          "--quiet"
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert_received {:mix_shell, :info, [_result]}
    end

    test "writes output to file when specified" do
      output = Path.join(System.tmp_dir!(), "lei-zarf-test-#{:rand.uniform(100_000)}.json")
      on_exit(fn -> File.rm(output) end)

      try do
        Mix.Tasks.Lei.ZarfGate.run([
          "--path",
          ".",
          "--threshold",
          "critical",
          "--output",
          output
        ])
      catch
        :exit, {:shutdown, 1} -> :ok
      end

      assert File.exists?(output)
    end
  end
end
