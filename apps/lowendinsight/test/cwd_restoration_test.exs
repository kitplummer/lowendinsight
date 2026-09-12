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

  describe "Files.find_binary_files/1" do
    test "restores the working directory for a path that cannot be entered", %{before: before} do
      missing = Path.join(System.tmp_dir!(), "lei-does-not-exist-#{System.unique_integer()}")

      # File.cd/1 returns {:error, :enoent}, which the old `else` clause could
      # not match -- it raised WithClauseError and skipped the restore.
      assert %{binary_files: [], binary_files_count: 0} = Lowendinsight.Files.find_binary_files(missing)

      assert File.cwd!() == before
    end

    test "restores the working directory for a directory with no matching files", %{
      tmp: tmp,
      before: before
    } do
      # `grep -rIL .` exits 1 when it matches nothing, which is not {_, 0}.
      assert %{binary_files_count: _} = Lowendinsight.Files.find_binary_files(tmp)

      assert File.cwd!() == before
    end
  end
end
