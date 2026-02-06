# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Cargo.Cargolock do
  @behaviour Parser

  @moduledoc """
    Provides Cargo.lock dependency parser for Rust projects.
    Parses [[package]] sections extracting locked dependency info
    including name, version, and source URLs.
  """

  @crates_io_registry "registry+https://github.com/rust-lang/crates.io-index"

  @impl Parser
  def parse!(content) do
    packages =
      content
      |> extract_packages()
      |> Enum.map(&normalize_package/1)

    {:ok, {packages, length(packages)}}
  end

  @impl Parser
  def file_names(), do: ["Cargo.lock"]

  defp extract_packages(content) do
    # Split by [[package]] markers and parse each block
    content
    |> String.split(~r/\[\[package\]\]/i)
    |> Enum.drop(1)
    |> Enum.map(&parse_package_block/1)
    |> Enum.filter(& &1)
  end

  defp parse_package_block(block) do
    lines = String.split(block, "\n")

    name = extract_field(lines, "name")
    version = extract_field(lines, "version")
    source = extract_field(lines, "source")

    if name && version do
      %{
        name: name,
        version: version,
        source: source,
        source_url: resolve_source_url(source)
      }
    else
      nil
    end
  end

  defp extract_field(lines, field) do
    pattern = ~r/^#{field}\s*=\s*"([^"]*)"/

    Enum.find_value(lines, fn line ->
      case Regex.run(pattern, String.trim(line)) do
        [_, value] -> value
        nil -> nil
      end
    end)
  end

  defp normalize_package(package) do
    {String.to_atom(package.name), package}
  end

  defp resolve_source_url(nil), do: nil

  defp resolve_source_url(source) do
    cond do
      # crates.io registry
      source == @crates_io_registry ->
        {:crates_io, nil}

      String.starts_with?(source, "registry+") ->
        {:registry, source}

      # Git source: git+https://github.com/user/repo?branch=main#commit
      String.starts_with?(source, "git+") ->
        parse_git_source(source)

      true ->
        {:unknown, source}
    end
  end

  defp parse_git_source(source) do
    # Remove "git+" prefix
    url = String.replace_prefix(source, "git+", "")

    # Split off the commit hash (after #)
    {base_url, commit} =
      case String.split(url, "#", parts: 2) do
        [base, hash] -> {base, hash}
        [base] -> {base, nil}
      end

    # Split off query params (after ?)
    {repo_url, _params} =
      case String.split(base_url, "?", parts: 2) do
        [repo, params] -> {repo, params}
        [repo] -> {repo, nil}
      end

    {:git, %{url: repo_url, commit: commit}}
  end
end
