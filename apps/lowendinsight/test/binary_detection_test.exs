defmodule BinaryDetectionTest do
  use ExUnit.Case, async: false

  alias Lowendinsight.Files

  @moduledoc """
  GET /url= hung forever in production while completing in under a second
  locally. The analysis shelled out to `grep -rIL .` with no file operand:
  GNU grep searches the working directory, BusyBox grep -- what an Alpine
  runtime provides -- reads stdin, and System.cmd holds the child's stdin open
  and never writes to it.

  No test could have caught that, because CI and this machine both have GNU
  grep. The guard below is therefore not "does grep behave" but "is there an
  external process at all": the tests run with PATH emptied, so any
  reintroduced System.cmd fails to find its executable.
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "lei-binary-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    path
  end

  describe "classification" do
    test "a file containing NUL is binary", %{tmp: tmp} do
      write(tmp, "blob.bin", <<0, 1, 2, 0, 255>>)

      assert %{binary_files: ["blob.bin"], binary_files_count: 1} = Files.find_binary_files(tmp)
    end

    test "a text file is not", %{tmp: tmp} do
      write(tmp, "readme.md", "hello, world\n")

      assert %{binary_files: [], binary_files_count: 0} = Files.find_binary_files(tmp)
    end

    test "an empty file is not binary", %{tmp: tmp} do
      write(tmp, "empty", "")

      assert %{binary_files: []} = Files.find_binary_files(tmp)
    end

    test "a NUL beyond the sniff window is not detected, by design", %{tmp: tmp} do
      # The heuristic reads the first 8KB, the same as git and grep. Stated so
      # the boundary is a decision on record rather than a surprise.
      write(tmp, "late.bin", String.duplicate("a", 9000) <> <<0>>)

      assert %{binary_files: []} = Files.find_binary_files(tmp)
    end

    test "finds binaries in subdirectories", %{tmp: tmp} do
      write(tmp, "nested/deep/img.png", <<137, 80, 78, 71, 0, 13>>)

      assert %{binary_files: ["nested/deep/img.png"]} = Files.find_binary_files(tmp)
    end

    test "results are sorted", %{tmp: tmp} do
      for name <- ["c.bin", "a.bin", "b.bin"], do: write(tmp, name, <<0>>)

      assert %{binary_files: ["a.bin", "b.bin", "c.bin"]} = Files.find_binary_files(tmp)
    end
  end

  describe "exclusions" do
    test "git internals are excluded", %{tmp: tmp} do
      write(tmp, ".git/objects/aa/bbcc", <<0, 1, 2>>)
      write(tmp, "real.bin", <<0>>)

      assert %{binary_files: ["real.bin"]} = Files.find_binary_files(tmp)
    end

    test "a dotfile that is not git is still scanned", %{tmp: tmp} do
      # Path.wildcard skips dotfiles unless asked. Losing them silently would
      # be the same shape of bug: fewer results, no error.
      write(tmp, ".hidden.bin", <<0>>)

      assert %{binary_files: [".hidden.bin"]} = Files.find_binary_files(tmp)
    end

    test "directories are not reported as files", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "somedir"))

      assert %{binary_files: []} = Files.find_binary_files(tmp)
    end

    test "a path that is not a directory yields nothing", %{tmp: _tmp} do
      missing = Path.join(System.tmp_dir!(), "lei-absent-#{System.unique_integer()}")

      assert %{binary_files: [], binary_files_count: 0} = Files.find_binary_files(missing)
    end
  end

  describe "no external process" do
    test "works with PATH emptied", %{tmp: tmp} do
      # This is the guard. The production hang came from shelling out to a grep
      # whose behaviour differs between GNU and BusyBox, and no assertion about
      # grep's behaviour can catch that on a machine with GNU grep. So assert
      # the absence of the dependency instead: with no PATH, System.cmd cannot
      # resolve an executable and raises.
      write(tmp, "blob.bin", <<0, 1>>)
      write(tmp, "notes.txt", "text")

      original = System.get_env("PATH")
      on_exit(fn -> if original, do: System.put_env("PATH", original) end)
      System.put_env("PATH", "")

      assert %{binary_files: ["blob.bin"], binary_files_count: 1} = Files.find_binary_files(tmp)
    end

    test "analyze_files works with PATH emptied too", %{tmp: tmp} do
      write(tmp, "README.md", "hi")
      write(tmp, "blob.bin", <<0>>)

      original = System.get_env("PATH")
      on_exit(fn -> if original, do: System.put_env("PATH", original) end)
      System.put_env("PATH", "")

      result = Files.analyze_files(tmp)

      assert result.binary_files == ["blob.bin"]
      assert result.has_readme == true
      assert result.total_file_count > 0
    end
  end

  describe "it terminates" do
    test "returns promptly on a tree with many files", %{tmp: tmp} do
      # The production symptom was a hang, not a wrong answer. A wall-clock
      # bound is crude but it is the property that actually failed.
      for n <- 1..200, do: write(tmp, "f#{n}.txt", "content #{n}")
      write(tmp, "one.bin", <<0>>)

      task = Task.async(fn -> Files.find_binary_files(tmp) end)

      assert %{binary_files: ["one.bin"]} = Task.await(task, 10_000)
    end
  end
end
