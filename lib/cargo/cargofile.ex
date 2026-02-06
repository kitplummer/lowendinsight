# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Cargo.Cargofile do
  @behaviour Parser

  @moduledoc """
    Provides Cargo.toml dependency parser for Rust projects.
    Parses [dependencies] and [dev-dependencies] sections,
    extracting crate names and version specs.
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

    Map.merge(deps, dev_deps)
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

        {name, version}

      # Simple string: serde = "1.0"
      Regex.match?(~r/^(\S+)\s*=\s*"([^"]*)"/, line) ->
        [_, name, version] = Regex.run(~r/^(\S+)\s*=\s*"([^"]*)"/, line)
        {name, version}

      true ->
        nil
    end
  end
end
