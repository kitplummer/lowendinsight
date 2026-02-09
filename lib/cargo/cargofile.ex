# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Cargo.Cargofile do
  @behaviour Parser

  @moduledoc """
    Provides Cargo.toml dependency parser for Rust projects.
    Parses [dependencies], [dev-dependencies], [build-dependencies],
    and [workspace.dependencies] sections, extracting crate names,
    version specs, and git/path source info.
  """

  @impl Parser
  def parse!(content) do
    deps =
      content
      |> extract_sections()
      |> extract_deps()
      |> Enum.to_list()

    {:ok, {deps, length(deps)}}
  end

  @impl Parser
  def file_names(), do: ["Cargo.toml"]

  defp extract_sections(content) do
    sections = parse_toml_sections(content)

    deps = Map.get(sections, "dependencies", %{})
    dev_deps = Map.get(sections, "dev-dependencies", %{})
    build_deps = Map.get(sections, "build-dependencies", %{})
    workspace_deps = Map.get(sections, "workspace.dependencies", %{})

    deps
    |> Map.merge(dev_deps)
    |> Map.merge(build_deps)
    |> Map.merge(workspace_deps)
  end

  defp extract_deps(deps_map) do
    Enum.map(deps_map, fn {name, version} ->
      {String.to_atom(name), version}
    end)
  end

  defp parse_toml_sections(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current_section, sections} ->
      line = String.trim(line)

      cond do
        # Skip comments and blank lines
        line == "" or String.starts_with?(line, "#") ->
          {current_section, sections}

        # Section header like [dependencies] or [dev-dependencies]
        Regex.match?(~r/^\[([^\[\]]+)\]$/, line) ->
          [_, section_name] = Regex.run(~r/^\[([^\[\]]+)\]$/, line)
          {section_name, Map.put_new(sections, section_name, %{})}

        # Key-value pair within a section
        current_section != nil ->
          case parse_dependency_line(line) do
            {name, version} ->
              updated =
                sections
                |> Map.get(current_section, %{})
                |> Map.put(name, version)

              {current_section, Map.put(sections, current_section, updated)}

            nil ->
              {current_section, sections}
          end

        true ->
          {current_section, sections}
      end
    end)
    |> elem(1)
  end

  defp parse_dependency_line(line) do
    cond do
      # Inline table: serde = { version = "1.0", features = ["derive"] }
      Regex.match?(~r/^(\S+)\s*=\s*\{/, line) ->
        [_, name] = Regex.run(~r/^(\S+)\s*=\s*\{/, line)

        version =
          case Regex.run(~r/version\s*=\s*"([^"]*)"/, line) do
            [_, v] -> v
            nil -> ""
          end

        git_url =
          case Regex.run(~r/git\s*=\s*"([^"]*)"/, line) do
            [_, url] -> url
            nil -> nil
          end

        path =
          case Regex.run(~r/path\s*=\s*"([^"]*)"/, line) do
            [_, p] -> p
            nil -> nil
          end

        cond do
          git_url != nil -> {name, %{git: git_url, version: version}}
          path != nil -> {name, %{path: path, version: version}}
          true -> {name, version}
        end

      # Simple string: serde = "1.0"
      Regex.match?(~r/^(\S+)\s*=\s*"([^"]*)"/, line) ->
        [_, name, version] = Regex.run(~r/^(\S+)\s*=\s*"([^"]*)"/, line)
        {name, version}

      true ->
        nil
    end
  end
end
