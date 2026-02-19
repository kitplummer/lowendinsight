# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.CachePullTaskTest do
  use ExUnit.Case, async: false

  describe "run/1" do
    test "reports usage error when no reference provided" do
      assert catch_exit(Mix.Tasks.Lei.Cache.Pull.run([])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage"
    end

    test "reports pull error for unreachable registry" do
      assert catch_exit(
               Mix.Tasks.Lei.Cache.Pull.run(["127.0.0.1:1/test/repo:latest"])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [pulling_msg]}
      assert pulling_msg =~ "Pulling"
      assert_received {:mix_shell, :error, [error_msg]}
      assert error_msg =~ "Pull failed"
    end

    test "uses custom output directory option" do
      output_dir = Path.join(System.tmp_dir!(), "lei-pull-test-#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(output_dir) end)

      assert catch_exit(
               Mix.Tasks.Lei.Cache.Pull.run([
                 "127.0.0.1:1/test/repo:v1",
                 "--output",
                 output_dir
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [pulling_msg]}
      assert pulling_msg =~ output_dir
    end
  end
end
