# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Sarif do
  @shortdoc "Run LowEndInsight scan and output SARIF for GitHub Security tab"
  @moduledoc ~S"""
  Analyze a project's dependencies and produce a SARIF 2.1.0 report suitable
  for upload to GitHub Code Scanning via the `github/codeql-action/upload-sarif` action.

  ## Usage

      mix lei.sarif [path] [--output <file>]

  ## Options

    * `--output` / `-o` - Write SARIF to file instead of stdout

  ## Examples

      mix lei.sarif
      mix lei.sarif . --output lei-results.sarif
      mix lei.sarif /path/to/project -o results.sarif
  """

  use Mix.Task

  @switches [output: :string]
  @aliases [o: :output]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, %{path: path, output: output}} <- parse_args(args) do
      scan_and_write(path, output)
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

        {:ok, %{path: path, output: Keyword.get(opts, :output)}}

      invalid ->
        names = Enum.map_join(invalid, ", ", fn {name, _value} -> name end)

        {:error, "Unknown option(s): #{names}. Usage: mix lei.sarif [path] [--output <file>]"}
    end
  end

  defp scan_and_write(path, output) do
    case File.exists?(path) do
      false ->
        Mix.shell().error("Invalid path: #{path}")

      true ->
        json = ScannerModule.scan(path)
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
