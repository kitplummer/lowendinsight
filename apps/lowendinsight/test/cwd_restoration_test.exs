defmodule CwdRestorationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The working directory is global to the BEAM node, not per-process. Code that
  cd's into a checkout and restores only on the happy path leaves the entire
  node pointing at a directory that is usually deleted moments later, and every
  subsequent relative path fails with "could not get current working directory".

  In the test suite this looked like an order-dependent cascade -- one failed
  scan invalidated whole modules that ran afterwards. In lowendinsight_get it
  means one failed analysis breaks the service until it restarts.
  """

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "lei-cwd-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp, before: File.cwd!()}
  end

  describe "ScannerModule.dependencies/1" do
    test "restores the working directory when the scan raises", %{tmp: tmp, before: before} do
      # No mix.lock in there, so File.read! raises partway through.
      assert_raise File.Error, fn -> ScannerModule.dependencies(tmp) end

      assert File.cwd!() == before
    end

    test "restores the working directory on success", %{before: before} do
      # The umbrella app root does have a mix.lock two levels up; scanning the
      # app directory itself is enough to exercise the happy path.
      path = File.cwd!()

      try do
        ScannerModule.dependencies(path)
      rescue
        _ -> :ok
      end

      assert File.cwd!() == before
    end
  end

  describe "ScannerModule.in_directory/2" do
    test "restores on a raise", %{tmp: tmp, before: before} do
      assert_raise RuntimeError, "boom", fn ->
        ScannerModule.in_directory(tmp, fn -> raise "boom" end)
      end

      assert File.cwd!() == before
    end

    test "restores on a throw", %{tmp: tmp, before: before} do
      catch_throw(ScannerModule.in_directory(tmp, fn -> throw(:nope) end))

      assert File.cwd!() == before
    end

    test "actually changes directory while the function runs", %{tmp: tmp} do
      # A no-op implementation would pass every restoration test above.
      inside = ScannerModule.in_directory(tmp, fn -> File.cwd!() end)

      assert Path.expand(inside) == Path.expand(tmp)
    end
  end

  describe "Lowendinsight.Files.find_binary_files/1" do
    test "never changes the working directory at all", %{tmp: tmp, before: before} do
      # Not "restores it" -- does not touch it. cwd is node-global and analyses
      # run concurrently, so a save-and-restore here is racy by construction:
      # another task can capture this task's temporary directory as its
      # "original" and restore into it after it has been deleted.
      File.write!(Path.join(tmp, "a.txt"), "hello")

      assert %{binary_files_count: _} = Lowendinsight.Files.find_binary_files(tmp)

      assert File.cwd!() == before
    end

    test "returns empty for a path that does not exist", %{before: before} do
      missing = Path.join(System.tmp_dir!(), "lei-does-not-exist-#{System.unique_integer()}")

      assert %{binary_files: [], binary_files_count: 0} =
               Lowendinsight.Files.find_binary_files(missing)

      assert File.cwd!() == before
    end

    test "returns empty for a directory with nothing in it", %{tmp: tmp, before: before} do
      # grep exits 1 when it matches nothing, which is not {_, 0}.
      assert %{binary_files: [], binary_files_count: 0} =
               Lowendinsight.Files.find_binary_files(tmp)

      assert File.cwd!() == before
    end

    test "still finds binary files when there are some", %{tmp: tmp} do
      # grep -rIL lists files *without* a match, treating binaries as
      # non-matching -- so a text file is correctly excluded and a file with
      # NUL bytes is reported.
      File.write!(Path.join(tmp, "readme.md"), "text")
      File.write!(Path.join(tmp, "blob.bin"), <<0, 1, 2, 0, 255>>)

      %{binary_files: files, binary_files_count: count} =
        Lowendinsight.Files.find_binary_files(tmp)

      assert "blob.bin" in files
      refute "readme.md" in files
      assert count == 1
    end

    test "concurrent calls do not corrupt the working directory", %{before: before} do
      # The failure this reproduces: several analyses run under
      # Task.async_stream, each against its own checkout, and the checkouts are
      # deleted as each finishes.
      dirs =
        for _ <- 1..8 do
          dir =
            Path.join(System.tmp_dir!(), "lei-cwd-race-#{:erlang.unique_integer([:positive])}")

          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "f.txt"), "x")
          dir
        end

      dirs
      |> Task.async_stream(
        fn dir ->
          result = Lowendinsight.Files.find_binary_files(dir)
          File.rm_rf!(dir)
          result
        end,
        max_concurrency: 8
      )
      |> Stream.run()

      assert File.cwd!() == before
    end
  end
end
