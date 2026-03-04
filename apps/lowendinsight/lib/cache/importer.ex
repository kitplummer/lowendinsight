# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.Importer do
  @moduledoc """
  Imports LEI cache snapshots from local directories or OCI artifacts.

  Supports two import modes:
  - Local directory import (from a previously exported or pulled cache)
  - OCI pull + import (pulls from registry, then imports)
  """

  require Logger

  @doc """
  Imports a cache snapshot from a local directory.

  Reads `manifest.json` and `cache.jsonl.gz` from the given directory.
  Returns `{:ok, manifest, reports}` where manifest is the cache metadata
  and reports is a list of decoded analysis report maps.
  """
  @spec import_local(String.t()) :: {:ok, map(), [map()]} | {:error, String.t()}
  def import_local(dir) do
    manifest_path = Path.join(dir, "manifest.json")
    jsonl_gz_path = Path.join(dir, "cache.jsonl.gz")

    with {:manifest, {:ok, manifest_data}} <- {:manifest, File.read(manifest_path)},
         {:manifest_decode, {:ok, manifest}} <- {:manifest_decode, Poison.decode(manifest_data)},
         {:jsonl, {:ok, reports}} <- {:jsonl, Lei.Cache.Exporter.read_jsonl(jsonl_gz_path)} do
      Logger.info(
        "Imported cache from #{dir}: #{length(reports)} entries, " <>
          "dated #{Map.get(manifest, "date", "unknown")}"
      )

      {:ok, manifest, reports}
    else
      {:manifest, {:error, reason}} ->
        {:error, "Cannot read manifest.json: #{inspect(reason)}"}

      {:manifest_decode, {:error, reason}} ->
        {:error, "Cannot parse manifest.json: #{inspect(reason)}"}

      {:jsonl, {:error, reason}} ->
        {:error, "Cannot read cache data: #{reason}"}
    end
  end

  @doc """
  Pulls a cache artifact from an OCI registry and saves to `target_dir`.

  Parses the OCI reference, pulls the manifest and blobs, and writes
  cache files to the target directory.

  Returns `{:ok, target_dir}` or `{:error, reason}`.
  """
  @spec pull(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def pull(oci_ref, target_dir, opts \\ []) do
    with {:ok, registry, repository, tag} <- Lei.Cache.OCIClient.parse_reference(oci_ref),
         {:ok, manifest} <-
           Lei.Cache.OCIClient.pull_manifest(registry, repository, tag, opts) do
      fetch_fn = fn digest ->
        Lei.Cache.OCIClient.pull_blob(registry, repository, digest, opts)
      end

      case Lei.Cache.OCI.unpack(manifest, target_dir, fetch_fn) do
        :ok ->
          Logger.info("Pulled cache artifact #{oci_ref} to #{target_dir}")
          {:ok, target_dir}

        {:error, _} = err ->
          err
      end
    end
  end
end
