# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.Cache.Export do
  @shortdoc "Export LEI analysis cache as OCI artifact"
  @moduledoc ~S"""
  Export LEI analysis reports as an OCI-compatible cache artifact for Zarf.

  Analyzes the given repositories, exports results as cache files,
  and optionally pushes to an OCI registry.

  ## Usage

      mix lei.cache.export <repo_urls_file> [options]
      mix lei.cache.export --input <jsonl_file> [options]

  ## Options

    * `--output` / `-o` - Output directory (default: `./lei-cache-YYYY-MM-DD`)
    * `--input` / `-i` - Import existing JSONL report file instead of analyzing
    * `--registry` / `-r` - OCI registry to push to (e.g., `ghcr.io/defenseunicorns/lei-cache`)
    * `--tag` / `-t` - Additional tag (date and latest are automatic)
    * `--token` - Registry auth token (or set `LEI_REGISTRY_TOKEN` env var)
    * `--date` - Override date tag (default: today's date)
    * `--push` - Push to registry after packaging (default: false)

  ## Examples

      # Export from analysis of repos listed in file
      mix lei.cache.export repos.txt -o ./cache-export

      # Export from existing JSONL and push to registry
      mix lei.cache.export --input results.jsonl --push -r ghcr.io/defenseunicorns/lei-cache

      # Export with custom date tag
      mix lei.cache.export repos.txt --date 2026-02-05 --push -r ghcr.io/defenseunicorns/lei-cache
  """

  use Mix.Task

  @switches [
    output: :string,
    input: :string,
    registry: :string,
    tag: :string,
    token: :string,
    date: :string,
    push: :boolean
  ]

  @aliases [o: :output, i: :input, r: :registry, t: :tag]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    date = Keyword.get(opts, :date, Date.to_iso8601(Date.utc_today()))
    output_dir = Keyword.get(opts, :output, "./lei-cache-#{date}")
    push = Keyword.get(opts, :push, false)

    reports =
      cond do
        Keyword.has_key?(opts, :input) ->
          load_from_jsonl(Keyword.get(opts, :input))

        length(positional) > 0 ->
          analyze_from_file(hd(positional))

        true ->
          Mix.shell().error(
            "Usage: mix lei.cache.export <repo_urls_file> [options]\n" <>
              "       mix lei.cache.export --input <jsonl_file> [options]"
          )

          exit({:shutdown, 1})
      end

    if reports == [] do
      Mix.shell().error("No reports to export")
      exit({:shutdown, 1})
    end

    Mix.shell().info("Exporting #{length(reports)} cache entries...")

    {:ok, export_dir} = Lei.Cache.Exporter.export(reports, output_dir, date: date)
    Mix.shell().info("Cache files written to #{export_dir}")

    {:ok, manifest_json, blobs} = Lei.Cache.OCI.package(export_dir)

    oci_manifest_path = Path.join(export_dir, "oci-manifest.json")
    File.write!(oci_manifest_path, manifest_json)
    Mix.shell().info("OCI manifest written to #{oci_manifest_path}")

    if push do
      push_to_registry(opts, date, manifest_json, blobs)
    else
      Mix.shell().info("Skipping push (use --push to push to registry)")
    end
  end

  defp load_from_jsonl(path) do
    case Lei.Cache.Exporter.read_jsonl(path) do
      {:ok, reports} ->
        Mix.shell().info("Loaded #{length(reports)} reports from #{path}")
        reports

      {:error, reason} ->
        Mix.shell().error("Error reading #{path}: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp analyze_from_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        urls =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))

        Mix.shell().info("Analyzing #{length(urls)} repositories...")

        urls
        |> Enum.map(fn url ->
          Mix.shell().info("  Analyzing #{url}...")

          case AnalyzerModule.analyze(url, "lei cache export", %{types: true}) do
            {:ok, report} -> report
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Mix.shell().error("Cannot read #{file_path}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp push_to_registry(opts, date, manifest_json, blobs) do
    registry = Keyword.get(opts, :registry)

    unless registry do
      Mix.shell().error("--registry is required when using --push")
      exit({:shutdown, 1})
    end

    token = Keyword.get(opts, :token) || System.get_env("LEI_REGISTRY_TOKEN")

    {registry_host, repository} = parse_registry(registry)

    date_parsed = Date.from_iso8601!(date)
    tags = Lei.Cache.OCIClient.generate_tags(date_parsed)

    extra_tag = Keyword.get(opts, :tag)
    tags = if extra_tag, do: tags ++ [extra_tag], else: tags

    Mix.shell().info("Pushing to #{registry} with tags: #{Enum.join(tags, ", ")}")

    case Lei.Cache.OCIClient.push(registry_host, repository, tags, manifest_json, blobs,
           token: token
         ) do
      :ok ->
        Mix.shell().info("Successfully pushed to #{registry}")

      {:error, reason} ->
        Mix.shell().error("Push failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp parse_registry(registry) do
    case String.split(registry, "/", parts: 2) do
      [host, repo] -> {host, repo}
      [host] -> {host, "lei-cache"}
    end
  end
end
