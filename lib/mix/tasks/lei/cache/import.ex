# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Cache.Import do
  @shortdoc "Import a LEI cache snapshot from a local directory"
  @moduledoc ~S"""
  Import a previously exported or pulled LEI cache snapshot.

  Reads the cache manifest and JSONL data from a local directory and
  displays a summary of the cache contents.

  ## Usage

      mix lei.cache.import <directory>

  ## Examples

      mix lei.cache.import ./lei-cache-2026-02-05
      mix lei.cache.import ./lei-cache-latest
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {_opts, positional, _} = OptionParser.parse(args, switches: [], aliases: [])

    case positional do
      [] ->
        Mix.shell().error("Usage: mix lei.cache.import <directory>")
        exit({:shutdown, 1})

      [dir | _] ->
        Mix.shell().info("Importing cache from #{dir}...")

        case Lei.Cache.Importer.import_local(dir) do
          {:ok, manifest, reports} ->
            print_summary(manifest, reports)

          {:error, reason} ->
            Mix.shell().error("Import failed: #{reason}")
            exit({:shutdown, 1})
        end
    end
  end

  defp print_summary(manifest, reports) do
    Mix.shell().info("")
    Mix.shell().info("=== LEI Cache Import Summary ===")
    Mix.shell().info("  Date:         #{Map.get(manifest, "date", "unknown")}")
    Mix.shell().info("  LEI Version:  #{Map.get(manifest, "lei_version", "unknown")}")
    Mix.shell().info("  Entries:      #{length(reports)}")
    Mix.shell().info("  Repos:        #{length(Map.get(manifest, "repos", []))}")
    Mix.shell().info("")

    repos = Map.get(manifest, "repos", [])

    if length(repos) > 0 do
      Mix.shell().info("  Repositories:")

      Enum.each(repos, fn repo ->
        Mix.shell().info("    - #{repo}")
      end)

      Mix.shell().info("")
    end

    Mix.shell().info("Cache imported successfully. #{length(reports)} analysis reports available.")
  end
end
