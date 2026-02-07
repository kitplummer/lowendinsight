# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.ExportCache do
  @shortdoc "Export cached analysis results to a portable bundle for airgap deployment"
  @moduledoc ~S"""
  Exports cached LowEndInsight analysis results to a portable bundle containing
  a SQLite database, gzipped JSON Lines, a manifest, and SHA-256 checksums.

  ## Usage

      mix lei.export_cache [--output <dir>]

  ## Options

    * `--output` - Base directory for the export bundle (default: system tmp dir)

  ## Output Structure

      lei-cache-YYYY-MM-DD/
      ├── manifest.json
      ├── cache.db          # SQLite (queryable)
      ├── cache.jsonl.gz    # JSON Lines (streaming)
      └── checksums.sha256

  ## Examples

      mix lei.export_cache
      mix lei.export_cache --output /path/to/exports

  ## Scheduling

  For nightly exports, schedule via cron:

      0 2 * * * cd /path/to/lei && mix lei.export_cache --output /exports
  """

  use Mix.Task

  @switches [output: :string]
  @aliases [o: :output]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    output = Keyword.get(opts, :output)

    Lei.Cache.init()

    case Lei.Cache.Exporter.export(output) do
      {:ok, bundle_dir, manifest} ->
        Mix.shell().info("Cache exported to #{bundle_dir}")
        Mix.shell().info("  Entries: #{manifest.entries}")
        Mix.shell().info("  Ecosystems: #{inspect(manifest.ecosystems)}")
        Mix.shell().info("  Format version: #{manifest.format_version}")

      {:error, msg} ->
        Mix.shell().error("Export failed: #{msg}")
    end
  end
end
