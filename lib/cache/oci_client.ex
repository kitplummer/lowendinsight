# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.OCIClient do
  @moduledoc """
  OCI Distribution Spec client for pushing and pulling LEI cache artifacts.

  Implements the subset of the OCI Distribution Specification needed to:
  - Push blobs and manifests to an OCI registry
  - Pull manifests and blobs from an OCI registry

  Supports token-based authentication (Bearer) as used by ghcr.io and
  other OCI-compliant registries.
  """

  require Logger

  @doc """
  Pushes an OCI artifact to a registry.

  ## Parameters
  - `registry` - Registry host (e.g., "ghcr.io")
  - `repository` - Repository path (e.g., "defenseunicorns/lei-cache")
  - `tags` - List of tags to apply (e.g., ["2026-02-05", "latest"])
  - `manifest_json` - The OCI manifest JSON string
  - `blobs` - List of `{digest, data}` tuples
  - `opts` - Options including `:token` for auth

  Returns `:ok` or `{:error, reason}`.
  """
  @spec push(String.t(), String.t(), [String.t()], String.t(), [{String.t(), binary()}], keyword()) ::
          :ok | {:error, String.t()}
  def push(registry, repository, tags, manifest_json, blobs, opts \\ []) do
    token = Keyword.get(opts, :token)
    base_url = "https://#{registry}/v2/#{repository}"

    with :ok <- push_blobs(base_url, blobs, token),
         :ok <- push_manifest(base_url, tags, manifest_json, token) do
      :ok
    end
  end

  @doc """
  Pulls an OCI manifest from a registry.

  Returns `{:ok, manifest_map}` or `{:error, reason}`.
  """
  @spec pull_manifest(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def pull_manifest(registry, repository, reference, opts \\ []) do
    token = Keyword.get(opts, :token)
    url = "https://#{registry}/v2/#{repository}/manifests/#{reference}"
    headers = auth_headers(token) ++ [{"Accept", Lei.Cache.OCI.manifest_media_type()}]

    case HTTPoison.get(url, headers, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Poison.decode(body)

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "Registry returned #{status}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  @doc """
  Pulls a blob from a registry by digest.

  Returns `{:ok, binary_data}` or `{:error, reason}`.
  """
  @spec pull_blob(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, String.t()}
  def pull_blob(registry, repository, digest, opts \\ []) do
    token = Keyword.get(opts, :token)
    url = "https://#{registry}/v2/#{repository}/blobs/#{digest}"
    headers = auth_headers(token)

    case HTTPoison.get(url, headers, recv_timeout: 60_000, follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "Registry returned #{status}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  @doc """
  Parses an OCI reference string into components.

  Supports formats:
  - `oci://registry/repo:tag`
  - `registry/repo:tag`

  Returns `{:ok, registry, repository, tag}` or `{:error, reason}`.
  """
  @spec parse_reference(String.t()) :: {:ok, String.t(), String.t(), String.t()} | {:error, String.t()}
  def parse_reference(ref) do
    ref = String.trim_leading(ref, "oci://")

    case String.split(ref, "/", parts: 2) do
      [registry, rest] ->
        case String.split(rest, ":") do
          [repository] ->
            {:ok, registry, repository, "latest"}

          [repository, tag] ->
            {:ok, registry, repository, tag}

          _ ->
            {:error, "Invalid OCI reference: #{ref}"}
        end

      _ ->
        {:error, "Invalid OCI reference: #{ref}"}
    end
  end

  @doc """
  Generates OCI tags for a given date.

  Returns a list of tags: the date tag, "latest", and optionally "weekly"
  if the date falls on a Sunday.
  """
  @spec generate_tags(Date.t()) :: [String.t()]
  def generate_tags(date \\ Date.utc_today()) do
    date_tag = Date.to_iso8601(date)
    day_of_week = Date.day_of_week(date)

    tags = [date_tag, "latest"]

    if day_of_week == 7 do
      tags ++ ["weekly"]
    else
      tags
    end
  end

  # --- Private ---

  defp push_blobs(base_url, blobs, token) do
    Enum.reduce_while(blobs, :ok, fn {digest, data}, _acc ->
      case check_blob_exists(base_url, digest, token) do
        true ->
          Logger.info("Blob #{digest} already exists, skipping")
          {:cont, :ok}

        false ->
          case upload_blob(base_url, digest, data, token) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp check_blob_exists(base_url, digest, token) do
    url = "#{base_url}/blobs/#{digest}"
    headers = auth_headers(token)

    case HTTPoison.head(url, headers, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: 200}} -> true
      _ -> false
    end
  end

  defp upload_blob(base_url, digest, data, token) do
    # Step 1: Initiate upload
    url = "#{base_url}/blobs/uploads/"
    headers = auth_headers(token) ++ [{"Content-Type", "application/octet-stream"}]

    case HTTPoison.post(url, "", headers, recv_timeout: 10_000) do
      {:ok, %HTTPoison.Response{status_code: status, headers: resp_headers}}
      when status in [202, 200] ->
        location = get_header(resp_headers, "location")

        if location do
          complete_upload(location, digest, data, token)
        else
          {:error, "No upload location returned"}
        end

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "Upload initiation failed (#{status}): #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP error initiating upload: #{inspect(reason)}"}
    end
  end

  defp complete_upload(location, digest, data, token) do
    # Step 2: Complete monolithic upload
    separator = if String.contains?(location, "?"), do: "&", else: "?"
    url = "#{location}#{separator}digest=#{URI.encode_www_form(digest)}"

    headers =
      auth_headers(token) ++
        [
          {"Content-Type", "application/octet-stream"},
          {"Content-Length", to_string(byte_size(data))}
        ]

    case HTTPoison.put(url, data, headers, recv_timeout: 120_000) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in [201, 200, 202] ->
        Logger.info("Uploaded blob #{digest} (#{byte_size(data)} bytes)")
        :ok

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "Upload completion failed (#{status}): #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP error completing upload: #{inspect(reason)}"}
    end
  end

  defp push_manifest(base_url, tags, manifest_json, token) do
    Enum.reduce_while(tags, :ok, fn tag, _acc ->
      url = "#{base_url}/manifests/#{tag}"

      headers =
        auth_headers(token) ++
          [{"Content-Type", Lei.Cache.OCI.manifest_media_type()}]

      case HTTPoison.put(url, manifest_json, headers, recv_timeout: 30_000) do
        {:ok, %HTTPoison.Response{status_code: status}} when status in [201, 200, 202] ->
          Logger.info("Pushed manifest with tag #{tag}")
          {:cont, :ok}

        {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
          {:halt, {:error, "Manifest push failed for tag #{tag} (#{status}): #{body}"}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:halt, {:error, "HTTP error pushing manifest: #{inspect(reason)}"}}
      end
    end)
  end

  defp auth_headers(nil), do: []
  defp auth_headers(token), do: [{"Authorization", "Bearer #{token}"}]

  defp get_header(headers, key) do
    key_lower = String.downcase(key)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == key_lower, do: v
    end)
  end
end
