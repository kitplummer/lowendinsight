# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.ExportCacheTaskTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure clean state - close DETS if open, delete ETS if exists
    :dets.close(:lei_cache_dets)

    try do
      :ets.delete(:lei_cache)
    rescue
      ArgumentError -> :ok
    end

    test_cache_dir =
      Path.join(System.tmp_dir!(), "lei_export_cache_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(test_cache_dir)
    Application.put_env(:lowendinsight, :cache_dir, test_cache_dir)

    on_exit(fn ->
      :dets.close(:lei_cache_dets)

      try do
        :ets.delete(:lei_cache)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf!(test_cache_dir)
      Application.delete_env(:lowendinsight, :cache_dir)
    end)

    {:ok, cache_dir: test_cache_dir}
  end

  test "reports error when cache is empty" do
    Mix.Tasks.Lei.ExportCache.run([])
    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "No cache entries"
  end

  test "exports cache entries successfully" do
    Lei.Cache.init()

    report = %{
      header: %{uuid: "test-uuid", start_time: "2026-01-01T00:00:00Z"},
      data: %{repo: "https://github.com/test/repo", risk: "low", project_types: %{}}
    }

    Lei.Cache.put("https://github.com/test/repo", report)

    output_dir =
      Path.join(System.tmp_dir!(), "lei-export-test-#{:erlang.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(output_dir) end)

    Mix.Tasks.Lei.ExportCache.run(["--output", output_dir])

    assert_received {:mix_shell, :info, [exported_msg]}
    assert exported_msg =~ "Cache exported to"
  end
end
