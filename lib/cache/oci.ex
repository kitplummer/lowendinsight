# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.OCI do
  @moduledoc """
  OCI artifact packaging for LEI cache snapshots.

  Builds OCI Image Manifest v2 artifacts containing LEI analysis cache data
  with custom media types for Zarf air-gap deployment.

  ## OCI Artifact Structure

      ghcr.io/defenseunicorns/lei-cache:2026-02-05
      ├── manifest.json   (application/vnd.lei.cache.manifest+json)
      └── cache.jsonl.gz  (application/vnd.lei.cache.jsonl+gzip)

  The OCI manifest wraps these as layers with proper digests and sizes.
  """

  @oci_manifest_media_type "application/vnd.oci.image.manifest.v1+json"
  @config_media_type "application/vnd.lei.cache.config.v1+json"
  @cache_manifest_media_type "application/vnd.lei.cache.manifest+json"
  @cache_jsonl_media_type "application/vnd.lei.cache.jsonl+gzip"

  @doc """
  Builds an OCI image manifest for the given cache layers.

  Accepts a list of layer descriptors (each with `:media_type`, `:digest`, `:size`,
  and optional `:annotations`) and a config descriptor.

  Returns the manifest as a map ready for JSON encoding.
  """
  @spec build_manifest(map(), [map()]) :: map()
  def build_manifest(config_descriptor, layer_descriptors) do
    %{
      schemaVersion: 2,
      mediaType: @oci_manifest_media_type,
      config: config_descriptor,
      layers: layer_descriptors,
      annotations: %{
        "org.opencontainers.image.created" => DateTime.to_iso8601(DateTime.utc_now()),
        "org.opencontainers.image.title" => "lei-cache",
        "org.opencontainers.image.description" => "LEI analysis cache snapshot",
        "org.opencontainers.image.vendor" => "GTRI"
      }
    }
  end

  @doc """
  Creates a blob descriptor from raw content bytes.

  Returns a map with `:media_type`, `:digest`, `:size`, and the raw `:data`.
  """
  @spec blob_descriptor(binary(), String.t()) :: map()
  def blob_descriptor(data, media_type) do
    digest = "sha256:" <> (:crypto.hash(:sha256, data) |> Base.encode16(case: :lower))
    size = byte_size(data)

    %{
      mediaType: media_type,
      digest: digest,
      size: size,
      data: data
    }
  end

  @doc """
  Packages cache files into OCI artifact layers.

  Takes a directory containing exported cache files and returns
  `{:ok, manifest_json, blobs}` where blobs is a list of `{digest, data}` tuples.
  """
  @spec package(String.t()) :: {:ok, String.t(), [{String.t(), binary()}]} | {:error, String.t()}
  def package(export_dir) do
    manifest_path = Path.join(export_dir, "manifest.json")
    jsonl_gz_path = Path.join(export_dir, "cache.jsonl.gz")

    with {:ok, manifest_data} <- read_file(manifest_path),
         {:ok, jsonl_gz_data} <- read_file(jsonl_gz_path) do
      manifest_blob = blob_descriptor(manifest_data, @cache_manifest_media_type)
      jsonl_gz_blob = blob_descriptor(jsonl_gz_data, @cache_jsonl_media_type)

      config = build_config(export_dir)
      config_json = Poison.encode!(config)
      config_blob = blob_descriptor(config_json, @config_media_type)

      layers = [
        %{mediaType: manifest_blob.mediaType, digest: manifest_blob.digest, size: manifest_blob.size},
        %{mediaType: jsonl_gz_blob.mediaType, digest: jsonl_gz_blob.digest, size: jsonl_gz_blob.size}
      ]

      config_ref = %{
        mediaType: config_blob.mediaType,
        digest: config_blob.digest,
        size: config_blob.size
      }

      oci_manifest = build_manifest(config_ref, layers)
      oci_manifest_json = Poison.encode!(oci_manifest, pretty: true)

      blobs = [
        {config_blob.digest, config_blob.data},
        {manifest_blob.digest, manifest_blob.data},
        {jsonl_gz_blob.digest, jsonl_gz_blob.data}
      ]

      {:ok, oci_manifest_json, blobs}
    end
  end

  @doc """
  Unpacks OCI artifact blobs into a target directory.

  Given a parsed OCI manifest and a function to fetch blobs by digest,
  writes the cache files to `target_dir`.
  """
  @spec unpack(map(), String.t(), (String.t() -> {:ok, binary()} | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def unpack(manifest, target_dir, fetch_blob_fn) do
    File.mkdir_p!(target_dir)

    layers = manifest["layers"] || manifest[:layers] || []

    Enum.reduce_while(layers, :ok, fn layer, _acc ->
      media_type = layer["mediaType"] || layer[:mediaType]
      digest = layer["digest"] || layer[:digest]

      filename = media_type_to_filename(media_type)

      case fetch_blob_fn.(digest) do
        {:ok, data} ->
          File.write!(Path.join(target_dir, filename), data)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "Failed to fetch blob #{digest}: #{reason}"}}
      end
    end)
  end

  @doc """
  Returns the OCI manifest media type.
  """
  def manifest_media_type, do: @oci_manifest_media_type

  @doc """
  Returns the config media type.
  """
  def config_media_type, do: @config_media_type

  @doc """
  Returns the cache manifest layer media type.
  """
  def cache_manifest_media_type, do: @cache_manifest_media_type

  @doc """
  Returns the cache JSONL layer media type.
  """
  def cache_jsonl_media_type, do: @cache_jsonl_media_type

  @doc """
  Maps an OCI layer media type to its expected filename.
  """
  @spec media_type_to_filename(String.t()) :: String.t()
  def media_type_to_filename(@cache_manifest_media_type), do: "manifest.json"
  def media_type_to_filename(@cache_jsonl_media_type), do: "cache.jsonl.gz"
  def media_type_to_filename(_), do: "unknown"

  defp build_config(export_dir) do
    manifest_path = Path.join(export_dir, "manifest.json")

    cache_meta =
      case File.read(manifest_path) do
        {:ok, data} ->
          case Poison.decode(data) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        _ ->
          %{}
      end

    %{
      "lei_version" => lowendinsight_version(),
      "created" => DateTime.to_iso8601(DateTime.utc_now()),
      "cache_entries" => Map.get(cache_meta, "entry_count", 0),
      "format_version" => "1.0"
    }
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp lowendinsight_version do
    case :application.get_key(:lowendinsight, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.9.0"
    end
  end
end
