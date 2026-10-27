# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Sarif do
  @shortdoc "Run LowEndInsight scan and output SARIF for GitHub Security tab"
  @moduledoc ~S"""
  Analyze a project's dependencies and produce a SARIF 2.1.0 report suitable
  for upload to GitHub Code Scanning via the `github/codeql-action/upload-sarif` action.

  ## Usage

      mix lei.sarif [path] [--output <file>] [--exclude <dir>]...

  ## Options

    * `--output` / `-o` - Write SARIF to file instead of stdout
    * `--exclude` - Leave out the manifests under this directory, relative to
      `path`. Repeatable. What it leaves out is printed, and a directory that
      does not exist is refused rather than excluding nothing.

  ## Examples

      mix lei.sarif
      mix lei.sarif . --output lei-results.sarif
      mix lei.sarif /path/to/project -o results.sarif
  """

  use Mix.Task

  @switches [output: :string, exclude: :keep]
  @aliases [o: :output]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, %{path: path, output: output, exclude: exclude}} <- parse_args(args),
         :ok <- check_excluded(path, exclude) do
      scan_and_write(path, output, exclude)
    else
      {:error, msg} -> Mix.shell().error(msg)
    end
  end

  @doc """
  Reads the arguments, refusing an unknown switch rather than crashing on it.

  `mix lei.sarif . --bogus` raised, printing a stack trace where a usage line
  belongs (checked 2026-09-16).
  """
  @spec parse_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_args(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    case invalid do
      [] ->
        path =
          case positional do
            [] -> "."
            [p | _] -> p
          end

        {:ok,
         %{
           path: path,
           output: Keyword.get(opts, :output),
           exclude: Keyword.get_values(opts, :exclude)
         }}

      invalid ->
        names = Enum.map_join(invalid, ", ", fn {name, _value} -> name end)

        {:error,
         "Unknown option(s): #{names}. Usage: mix lei.sarif [path] [--output <file>] [--exclude <dir>]..."}
    end
  end

  # An exclusion that names no directory excludes nothing, silently: a typo, or
  # a directory renamed since the workflow was written. Refused instead.
  defp check_excluded(_path, []), do: :ok

  defp check_excluded(path, exclude) do
    case Enum.reject(exclude, &File.dir?(Path.join(path, &1))) do
      [] ->
        report_excluded(path, exclude)

      missing ->
        {:error, "--exclude names no directory under #{path}: #{Enum.join(missing, ", ")}"}
    end
  end

  # Leaving something out of a supply-chain scan is a decision, so it is said.
  defp report_excluded(path, exclude) do
    all = ProjectIdent.get_project_types_identified(path)
    kept = ProjectIdent.get_project_types_identified(path, exclude: exclude)
    left_out = (Map.values(all) |> List.flatten()) -- (Map.values(kept) |> List.flatten())
    root = Path.expand(path)

    Mix.shell().info(
      "Excluded from the scan (#{Enum.join(exclude, ", ")}): " <>
        case left_out do
          [] -> "no manifests"
          files -> Enum.map_join(files, ", ", &Path.relative_to(Path.expand(&1), root))
        end
    )
  end

  defp scan_and_write(path, output, exclude) do
    case File.exists?(path) do
      false ->
        Mix.shell().error("Invalid path: #{path}")

      true ->
        json = ScannerModule.scan(path, exclude: exclude)
        report = Poison.decode!(json, keys: :atoms)

        case Lei.Sarif.generate(report) do
          {:ok, sarif_json} ->
            if output do
              File.write!(output, sarif_json)
              Mix.shell().info("SARIF written to #{output}")
            else
              Mix.shell().info(sarif_json)
            end

          {:error, msg} ->
            Mix.shell().error("Error generating SARIF: #{msg}")
        end
    end
  end
end
