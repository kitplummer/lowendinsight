# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Registry do
  @moduledoc """
  Resolves package names to source repository URLs by querying package registries.
  """
  require Logger

  @spec resolve_repo_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_repo_url(ecosystem, package) do
    HTTPoison.start()

    case ecosystem do
      "hex" -> resolve_hex(package)
      "npm" -> resolve_npm(package)
      "pypi" -> resolve_pypi(package)
      "cargo" -> resolve_cargo(package)
      _ -> {:error, "unsupported ecosystem: #{ecosystem}"}
    end
  end

  defp resolve_hex(package) do
    case HTTPoison.get("https://hex.pm/api/packages/#{URI.encode(package)}") do
      {:ok, %{status_code: 200, body: body}} ->
        links = Poison.decode!(body)["meta"]["links"]
        links = for {k, v} <- links, into: %{}, do: {String.downcase(k), v}

        url =
          links["github"] || links["bitbucket"] || links["gitlab"] ||
            links["repository"] || links["source"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for hex/#{package}"}

      {:ok, %{status_code: status}} ->
        {:error, "hex.pm returned #{status} for #{package}"}

      {:error, reason} ->
        {:error, "hex lookup failed for #{package}: #{inspect(reason)}"}
    end
  end

  defp resolve_npm(package) do
    encoded = URI.encode(package)

    case HTTPoison.get("https://replicate.npmjs.com/" <> encoded) do
      {:ok, %{status_code: 200, body: body}} ->
        decoded = Poison.decode!(body)

        case decoded["repository"] do
          %{"url" => url} when is_binary(url) -> {:ok, url}
          _ -> {:error, "no repo URL for npm/#{package}"}
        end

      {:ok, %{status_code: status}} ->
        {:error, "npm returned #{status} for #{package}"}

      {:error, reason} ->
        {:error, "npm lookup failed for #{package}: #{inspect(reason)}"}
    end
  end

  defp resolve_pypi(package) do
    encoded = URI.encode(package)

    case HTTPoison.get("https://pypi.org/pypi/" <> encoded <> "/json") do
      {:ok, %{status_code: 200, body: body}} ->
        info = Poison.decode!(body)["info"]
        urls = info["project_urls"] || %{}

        url =
          urls["Code"] || urls["Source Code"] || urls["Source"] ||
            urls["Repository"] || urls["Homepage"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for pypi/#{package}"}

      {:ok, %{status_code: status}} ->
        {:error, "pypi returned #{status} for #{package}"}

      {:error, reason} ->
        {:error, "pypi lookup failed for #{package}: #{inspect(reason)}"}
    end
  end

  defp resolve_cargo(package) do
    case HTTPoison.get("https://crates.io/api/v1/crates/#{URI.encode(package)}",
           [{"User-Agent", "lowendinsight/0.9.0"}]) do
      {:ok, %{status_code: 200, body: body}} ->
        crate = Poison.decode!(body)["crate"]
        url = crate["repository"]

        if url, do: {:ok, url}, else: {:error, "no repo URL for cargo/#{package}"}

      {:ok, %{status_code: status}} ->
        {:error, "crates.io returned #{status} for #{package}"}

      {:error, reason} ->
        {:error, "cargo lookup failed for #{package}: #{inspect(reason)}"}
    end
  end
end
