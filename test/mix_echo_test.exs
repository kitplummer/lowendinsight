# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.EchoTest do
  use ExUnit.Case, async: true

  test "echoes arguments joined by space" do
    Mix.Tasks.Echo.run(["hello", "world"])
    assert_received {:mix_shell, :info, ["hello world"]}
  end

  test "echoes single argument" do
    Mix.Tasks.Echo.run(["hello"])
    assert_received {:mix_shell, :info, ["hello"]}
  end

  test "echoes empty arguments" do
    Mix.Tasks.Echo.run([])
    assert_received {:mix_shell, :info, [""]}
  end
end
