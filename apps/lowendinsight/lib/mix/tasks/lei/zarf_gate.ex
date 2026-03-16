# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.ZarfGate do
  @shortdoc "Run LEI risk gate for Zarf pre-package assessment"
  @moduledoc ~S"""
  Run LEI supply chain risk analysis as a pre-package gate for Zarf.

  Analyzes dependencies in a project directory or specific git repositories,
  evaluates risk against a configurable threshold, and exits with a non-zero
  status if any dependency exceeds the threshold.

  ## Usage

      # Scan a local project directory
      mix lei.zarf_gate --path ./my-project --threshold high

      # Analyze specific git repositories
      mix lei.zarf_gate --repo https://github.com/org/repo1 --repo https://github.com/org/repo2

      # Output in SARIF format for CI/CD
      mix lei.zarf_gate --path . --format sarif --output lei-results.sarif

  ## Options

    * `--path` - Path to project directory to scan (default: current directory)
    * `--repo` - Git repository URL to analyze (can be specified multiple times)
    * `--threshold` - Risk threshold: `low`, `medium`, `high`, `critical` (default: `high`)
    * `--format` - Output format: `json` or `sarif` (default: `json`)
    * `--output` - Write output to file instead of stdout
    * `--quiet` - Suppress informational output, only show results

  ## Exit Codes

    * `0` - All dependencies pass the risk threshold
    * `1` - One or more dependencies exceed the risk threshold

  ## Zarf Integration

  Add to your `zarf.yaml` as an action hook:

      components:
        - name: mission-app
          actions:
            onCreate:
              before:
                - cmd: mix lei.zarf_gate --path . --threshold high --format json
                  description: "LEI supply chain risk assessment"
  """

  use Mix.Task

  @switches [
    path: :string,
    repo: [:string, :keep],
    threshold: :string,
    format: :string,
    output: :string,
    quiet: :boolean
  ]
  @aliases [p: :path, r: :repo, t: :threshold, f: :format, o: :output, q: :quiet]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    threshold = Keyword.get(opts, :threshold, "high")
    format = Keyword.get(opts, :format, "json")
    output = Keyword.get(opts, :output)
    quiet = Keyword.get(opts, :quiet, false)

    repos = Keyword.get_values(opts, :repo)
    path = Keyword.get(opts, :path)

    report = get_report(repos, path, quiet)

    case report do
      {:error, msg} ->
        Mix.shell().error("Error: #{msg}")
        exit({:shutdown, 1})

      {:ok, lei_report} ->
        case Lei.ZarfGate.evaluate(lei_report, threshold) do
          {:ok, gate_result} ->
            output_result(gate_result, format, output, quiet)

            unless gate_result.pass do
              exit({:shutdown, 1})
            end

          {:error, msg} ->
            Mix.shell().error("Gate evaluation error: #{msg}")
            exit({:shutdown, 1})
        end
    end
  end

  defp get_report(repos, _path, quiet) when length(repos) > 0 do
    unless quiet, do: Mix.shell().info("Analyzing #{length(repos)} repositories...")

    {:ok, report} =
      AnalyzerModule.analyze(repos, "lei-zarf-gate", DateTime.utc_now(), %{types: true})

    {:ok, report}
  end

  defp get_report(_repos, path, quiet) do
    scan_path = path || "."

    unless quiet, do: Mix.shell().info("Scanning project at #{scan_path}...")

    if File.exists?(scan_path) do
      json = ScannerModule.scan(scan_path)
      report = Poison.decode!(json, keys: :atoms)
      {:ok, report}
    else
      {:error, "Path does not exist: #{scan_path}"}
    end
  end

  defp output_result(gate_result, format, output_file, quiet) do
    {:ok, formatted} =
      case format do
        "sarif" ->
          Lei.ZarfGate.Sarif.generate(gate_result)

        _ ->
          Lei.ZarfGate.to_json(gate_result)
      end

    if output_file do
      File.write!(output_file, formatted)
      unless quiet, do: Mix.shell().info("Results written to #{output_file}")
    else
      Mix.shell().info(formatted)
    end

    unless quiet do
      if gate_result.pass do
        Mix.shell().info(
          "GATE PASSED: #{gate_result.summary.total} dependencies analyzed, all within #{gate_result.threshold} threshold"
        )
      else
        Mix.shell().error(
          "GATE FAILED: #{gate_result.summary.failing}/#{gate_result.summary.total} dependencies exceed #{gate_result.threshold} threshold"
        )
      end
    end
  end
end
