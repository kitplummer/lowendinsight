# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.SbomParser do
  @moduledoc """
  Parses SBOM formats (CycloneDX, SPDX) and extracts git repository URLs.

  Supports:
  - CycloneDX 1.4+ JSON
  - SPDX 2.3 JSON
  """

  require Logger

  @git_url_patterns [
    ~r{https?://github\.com/[^/]+/[^/\s\?#]+},
    ~r{https?://gitlab\.com/[^/]+/[^/\s\?#]+},
    ~r{https?://bitbucket\.org/[^/]+/[^/\s\?#]+},
    ~r{git://[^\s]+},
    ~r{git@[^:]+:[^/]+/[^\s]+\.git}
  ]

  @doc """
  Parse SBOM and extract git URLs.

  Returns `{:ok, urls}` or `{:error, reason}`.
  """
  def parse(sbom_content) when is_binary(sbom_content) do
    case Poison.decode(sbom_content) do
      {:ok, sbom} -> parse_json(sbom)
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  def parse(sbom) when is_map(sbom), do: parse_json(sbom)

  defp parse_json(sbom) do
    cond do
      # CycloneDX format detection
      Map.has_key?(sbom, "bomFormat") or Map.has_key?(sbom, "components") ->
        parse_cyclonedx(sbom)

      # SPDX format detection
      Map.has_key?(sbom, "spdxVersion") or Map.has_key?(sbom, "packages") ->
        parse_spdx(sbom)

      true ->
        {:error, "unrecognized SBOM format (expected CycloneDX or SPDX)"}
    end
  end

  @doc """
  Parse CycloneDX SBOM and extract git URLs from components.
  """
  def parse_cyclonedx(sbom) do
    components = Map.get(sbom, "components", [])

    urls =
      components
      |> Enum.flat_map(&extract_cyclonedx_urls/1)
      |> Enum.uniq()
      |> Enum.filter(&valid_git_url?/1)

    Logger.debug(
      "CycloneDX: extracted #{length(urls)} git URLs from #{length(components)} components"
    )

    {:ok, urls}
  end

  defp extract_cyclonedx_urls(component) do
    urls = []

    # Extract from externalReferences
    external_refs = Map.get(component, "externalReferences", [])

    ref_urls =
      Enum.flat_map(external_refs, fn ref ->
        case ref do
          %{"type" => type, "url" => url} when type in ["vcs", "website", "distribution"] ->
            extract_git_url(url)

          _ ->
            []
        end
      end)

    # Extract from purl (Package URL)
    purl_urls =
      case Map.get(component, "purl") do
        nil -> []
        purl -> extract_urls_from_purl(purl)
      end

    # Try to construct URL from component metadata
    metadata_urls = extract_from_component_metadata(component)

    urls ++ ref_urls ++ purl_urls ++ metadata_urls
  end

  @doc """
  Parse SPDX SBOM and extract git URLs from packages.
  """
  def parse_spdx(sbom) do
    packages = Map.get(sbom, "packages", [])

    urls =
      packages
      |> Enum.flat_map(&extract_spdx_urls/1)
      |> Enum.uniq()
      |> Enum.filter(&valid_git_url?/1)

    Logger.debug("SPDX: extracted #{length(urls)} git URLs from #{length(packages)} packages")
    {:ok, urls}
  end

  defp extract_spdx_urls(package) do
    urls = []

    # Extract from externalRefs
    external_refs = Map.get(package, "externalRefs", [])

    ref_urls =
      Enum.flat_map(external_refs, fn ref ->
        case ref do
          %{"referenceType" => "purl", "referenceLocator" => purl} ->
            extract_urls_from_purl(purl)

          %{"referenceType" => "vcs", "referenceLocator" => url} ->
            extract_git_url(url)

          _ ->
            []
        end
      end)

    # Extract from downloadLocation
    download_urls =
      case Map.get(package, "downloadLocation") do
        nil -> []
        "NOASSERTION" -> []
        url -> extract_git_url(url)
      end

    # Extract from homepage
    homepage_urls =
      case Map.get(package, "homepage") do
        nil -> []
        url -> extract_git_url(url)
      end

    urls ++ ref_urls ++ download_urls ++ homepage_urls
  end

  @doc """
  Extract git URLs from a Package URL (purl).

  Examples:
  - pkg:github/owner/repo@version -> https://github.com/owner/repo
  - pkg:npm/%40scope/name -> lookup on registry (not implemented yet)
  """
  def extract_urls_from_purl(purl) when is_binary(purl) do
    case parse_purl(purl) do
      {:ok, %{type: "github", namespace: namespace, name: name}} ->
        ["https://github.com/#{namespace}/#{name}"]

      {:ok, %{type: "gitlab", namespace: namespace, name: name}} ->
        ["https://gitlab.com/#{namespace}/#{name}"]

      {:ok, %{type: "bitbucket", namespace: namespace, name: name}} ->
        ["https://bitbucket.org/#{namespace}/#{name}"]

      _ ->
        []
    end
  end

  defp parse_purl(purl) do
    # Simple purl parser: pkg:type/namespace/name@version?qualifiers#subpath
    case Regex.run(~r{^pkg:([^/]+)/([^/]+)/([^@\?#]+)}, purl) do
      [_, type, namespace, name] ->
        {:ok, %{type: type, namespace: URI.decode(namespace), name: URI.decode(name)}}

      _ ->
        # Try without namespace: pkg:type/name@version
        case Regex.run(~r{^pkg:([^/]+)/([^@\?#]+)}, purl) do
          [_, type, name] ->
            {:ok, %{type: type, namespace: nil, name: URI.decode(name)}}

          _ ->
            {:error, "invalid purl format"}
        end
    end
  end

  defp extract_from_component_metadata(component) do
    # Try to construct github URL from group/name for common ecosystems
    case {Map.get(component, "group"), Map.get(component, "name")} do
      {nil, _} ->
        []

      {group, name} when is_binary(group) and is_binary(name) ->
        # Check if group looks like a github org
        if String.match?(group, ~r{^[a-zA-Z0-9_-]+$}) and
             String.match?(name, ~r{^[a-zA-Z0-9_.-]+$}) do
          # This is speculative - might not always be a valid github repo
          []
        else
          []
        end

      _ ->
        []
    end
  end

  defp extract_git_url(url) when is_binary(url) do
    @git_url_patterns
    |> Enum.flat_map(fn pattern ->
      case Regex.run(pattern, url) do
        [match | _] -> [normalize_git_url(match)]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp normalize_git_url(url) do
    url
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
    # Remove fragment
    |> String.replace(~r{#.*$}, "")
    # Remove query string
    |> String.replace(~r{\?.*$}, "")
  end

  defp valid_git_url?(url) do
    # Basic validation - must be a proper git host URL
    Enum.any?(@git_url_patterns, fn pattern ->
      Regex.match?(pattern, url)
    end)
  end
end
