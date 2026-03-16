# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Cache.Pull do
  @shortdoc "Pull LEI cache artifact from an OCI registry"
  @moduledoc ~S"""
  Pull a LEI cache artifact from an OCI registry for air-gapped use.

  ## Usage

      mix lei.cache.pull <oci_reference> [options]

  ## Options

    * `--output` / `-o` - Output directory (default: `./lei-cache-<tag>`)
    * `--token` - Registry auth token (or set `LEI_REGISTRY_TOKEN` env var)

  ## OCI Reference Format

      oci://ghcr.io/defenseunicorns/lei-cache:latest
      oci://ghcr.io/defenseunicorns/lei-cache:2026-02-05
      ghcr.io/defenseunicorns/lei-cache:weekly

  ## Examples

      mix lei.cache.pull oci://ghcr.io/defenseunicorns/lei-cache:latest
      mix lei.cache.pull oci://ghcr.io/defenseunicorns/lei-cache:2026-02-05 -o ./my-cache
  """

  use Mix.Task

  @switches [output: :string, token: :string]
  @aliases [o: :output]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case positional do
      [] ->
        Mix.shell().error("Usage: mix lei.cache.pull <oci_reference> [--output <dir>]")
        exit({:shutdown, 1})

      [oci_ref | _] ->
        token = Keyword.get(opts, :token) || System.get_env("LEI_REGISTRY_TOKEN")

        {:ok, _registry, _repository, tag} = Lei.Cache.OCIClient.parse_reference(oci_ref)
        output_dir = Keyword.get(opts, :output, "./lei-cache-#{tag}")

        Mix.shell().info("Pulling #{oci_ref} to #{output_dir}...")

        case Lei.Cache.Importer.pull(oci_ref, output_dir, token: token) do
          {:ok, dir} ->
            Mix.shell().info("Cache artifact saved to #{dir}")

          {:error, reason} ->
            Mix.shell().error("Pull failed: #{reason}")
            exit({:shutdown, 1})
        end
    end
  end
end
