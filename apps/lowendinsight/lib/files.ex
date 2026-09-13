# Copyright (C) 2022 by Kit Plummer
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lowendinsight.Files do
  @spec analyze_files(binary) :: %{
          binary_files: list,
          binary_files_count: non_neg_integer,
          has_contributing: boolean,
          has_license: boolean,
          has_readme: boolean,
          total_file_count: non_neg_integer
        }
  def analyze_files(path) do
    binaries = find_binary_files(path)
    res = Map.merge(binaries, get_total_file_count(path))
    res = Map.merge(res, has_readme?(path))
    res = Map.merge(res, has_license?(path))
    Map.merge(res, has_contributing?(path))
  end

  @spec find_binary_files(
          binary
          | maybe_improper_list(
              binary | maybe_improper_list(any, binary | []) | char,
              binary | []
            )
        ) :: %{binary_files: list, binary_files_count: non_neg_integer}
  def find_binary_files(path) do
    # Implemented in Elixir rather than by shelling out to grep, because
    # shelling out was broken in production in two separate ways.
    #
    # The command was `grep -rIL .` with no file operand. GNU grep defaults to
    # searching the working directory; BusyBox grep -- which is what an Alpine
    # runtime image provides, and ours has no grep package -- reads **stdin**
    # instead. System.cmd holds the child's stdin open and never writes to it,
    # so grep blocked forever and every analysis hung after the clone. That is
    # why GET /url= never returned in production while completing in under a
    # second locally against GNU grep.
    #
    # Fixing the operand alone would not have been enough: BusyBox accepts -I
    # but does not implement GNU's binary-file semantics, so `grep -rIL . .`
    # reports nothing for a directory containing a binary file. The function
    # would have stopped hanging and started quietly returning [].
    #
    # The NUL-byte-in-the-first-8KB heuristic below is the same one git and
    # grep use to classify a file as binary.
    binary_files =
      if File.dir?(path) do
        path
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Stream.reject(&git_internal?(&1, path))
        |> Stream.filter(&File.regular?/1)
        |> Stream.filter(&binary?/1)
        |> Stream.map(&relative_to(&1, path))
        |> Enum.sort()
      else
        []
      end

    %{binary_files: binary_files, binary_files_count: Enum.count(binary_files)}
  end

  @binary_sniff_bytes 8000

  defp binary?(file) do
    case File.open(file, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @binary_sniff_bytes) do
            data when is_binary(data) -> String.contains?(data, <<0>>)
            # :eof for an empty file, which is not binary.
            _ -> false
          end
        after
          File.close(io)
        end

      # Unreadable is not the same as binary, and one bad file must not fail
      # the analysis of a whole repository.
      {:error, _reason} ->
        false
    end
  end

  defp git_internal?(file, path) do
    relative = relative_to(file, path)

    relative == ".git" or String.starts_with?(relative, ".git/") or
      String.contains?(relative, "/.git/")
  end

  defp relative_to(file, path) do
    file
    |> Path.relative_to(path)
    |> String.trim_leading("./")
  end

  @spec get_total_file_count(binary) :: %{total_file_count: non_neg_integer}
  def get_total_file_count(path) do
    all_files =
      Path.wildcard(path <> "/**")
      |> Enum.reject(&(String.contains?(&1, ".git/") || &1 == ""))

    total_file_count = Enum.count(all_files)
    %{total_file_count: total_file_count}
  end

  @spec has_readme?(binary) :: %{has_readme: boolean}
  def has_readme?(path) do
    readmes =
      Path.wildcard(path <> "/readme*") ++ Path.wildcard(path <> "/README*")

    %{has_readme: !Enum.empty?(readmes)}
  end

  @spec has_license?(binary) :: %{has_license: boolean}
  def has_license?(path) do
    licenses =
      Path.wildcard(path <> "/license*") ++ Path.wildcard(path <> "/LICENSE*")

    %{has_license: !Enum.empty?(licenses)}
  end

  @spec has_contributing?(binary) :: %{has_contributing: boolean}
  def has_contributing?(path) do
    contributings =
      Path.wildcard(path <> "/contributing*") ++ Path.wildcard(path <> "/CONTRIBUTING*")

    %{has_contributing: !Enum.empty?(contributings)}
  end
end
