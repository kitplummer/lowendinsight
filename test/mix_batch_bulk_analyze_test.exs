# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.BatchBulkAnalyzeTest do
  use ExUnit.Case, async: false

  describe "run/1 with invalid URLs (no network needed)" do
    test "processes file and passes to BulkAnalyze which reports invalid contents" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-batch-invalid-#{:rand.uniform(100_000)}.txt")
      File.write!(tmp_file, "not_a_url\nanother_bad_line\n")
      on_exit(fn -> File.rm(tmp_file); File.rm("temp.txt") end)

      Mix.Tasks.Lei.BatchBulkAnalyze.run([tmp_file])

      # BulkAnalyze.run validates URLs and should report invalid contents
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "invalid file contents"
    end
  end

  describe "run/1 with network" do
    @describetag :network
    @describetag :long

    test "processes file in batches" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-batch-test-#{:rand.uniform(100_000)}.txt")

      File.write!(tmp_file, "https://github.com/kitplummer/xmpp4rails\n")
      on_exit(fn -> File.rm(tmp_file); File.rm("temp.txt") end)

      Mix.Tasks.Lei.BatchBulkAnalyze.run([tmp_file])

      # Should have produced output via BulkAnalyze
      assert_received {:mix_shell, :info, [_report]}
    end
  end
end
