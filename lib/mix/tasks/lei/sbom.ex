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

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case positional do
      [] ->
        Mix.shell().error("Usage: mix lei.sbom <repo_url> [--format cyclonedx|spdx] [--output <file>]")

      [url | _] ->
        format = Keyword.get(opts, :format, "cyclonedx")
        output = Keyword.get(opts, :output)

        {:ok, report} = AnalyzerModule.analyze(url, "mix lei.sbom", %{types: true})

        result =
          case format do
            "spdx" ->
              Lei.Sbom.SPDX.generate(report)

            "cyclonedx" ->
              Lei.Sbom.CycloneDX.generate(report)

            _ ->
              {:error, "Unknown format '#{format}'. Use 'cyclonedx' or 'spdx'."}
          end

        case result do
          {:ok, json} ->
            if output do
              File.write!(output, json)
              Mix.shell().info("SBOM written to #{output}")
            else
              Mix.shell().info(json)
            end

          {:error, msg} ->
            Mix.shell().error("Error: #{msg}")
        end
    end
  end
end
