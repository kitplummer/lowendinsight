# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Sbom do
  @shortdoc "Generate SBOM (CycloneDX 1.4 or SPDX 2.3) from LowEndInsight analysis"
  @moduledoc ~S"""
  Analyze a git repository and produce an SBOM in CycloneDX 1.4 or SPDX 2.3 JSON format.
  Bus-factor risk scores from LowEndInsight are embedded as custom properties.

  ## Usage

      mix lei.sbom <repo_url> [--format cyclonedx|spdx] [--output <file>]

  ## Options

    * `--format` - SBOM format: `cyclonedx` (default) or `spdx`
    * `--output` - Write output to file instead of stdout

  ## Examples

      mix lei.sbom "https://github.com/kitplummer/xmpp4rails"
      mix lei.sbom "https://github.com/kitplummer/xmpp4rails" --format spdx
      mix lei.sbom "https://github.com/kitplummer/xmpp4rails" --format cyclonedx --output bom.json
  """

  use Mix.Task

  @switches [format: :string, output: :string]
  @aliases [f: :format, o: :output]

  @formats ~w(cyclonedx spdx)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:error, msg} ->
        Mix.shell().error(msg)

      {:ok, %{url: url, format: format, output: output}} ->
        {:ok, report} = AnalyzerModule.analyze(url, "mix lei.sbom", %{types: true})

        result =
          case format do
            "spdx" -> Lei.Sbom.SPDX.generate(report)
            "cyclonedx" -> Lei.Sbom.CycloneDX.generate(report)
          end

        # Both generators return {:ok, json}; a bad format is refused above.
        {:ok, json} = result

        if output do
          File.write!(output, json)
          Mix.shell().info("SBOM written to #{output}")
        else
          Mix.shell().info(json)
        end
    end
  end

  @doc """
  Reads the arguments, refusing a bad one before any work is done.

  The format used to be checked after the repository had been analysed, so a
  typo cost a full clone before saying so.
  """
  @spec parse_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_args(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = Keyword.get(opts, :format, "cyclonedx")

    cond do
      positional == [] ->
        {:error, "Usage: mix lei.sbom <repo_url> [--format cyclonedx|spdx] [--output <file>]"}

      format not in @formats ->
        {:error, "Unknown format '#{format}'. Use 'cyclonedx' or 'spdx'."}

      true ->
        {:ok, %{url: hd(positional), format: format, output: Keyword.get(opts, :output)}}
    end
  end
end
