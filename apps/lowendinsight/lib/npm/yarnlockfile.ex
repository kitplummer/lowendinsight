# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Npm.Yarnlockfile do
  @behaviour Parser

  @moduledoc """
    Provides yarn.lock dependency parser
  """

  @impl Parser
  def parse!(content) do
    deps =
      content
      |> decode!()
      |> Enum.flat_map(&package_version/1)
      |> Enum.reduce(%{}, fn {name, version}, acc ->
        Map.update(acc, name, version, &newer_version(&1, version))
      end)
      |> Enum.to_list()

    {:ok, {deps, length(deps)}}
  end

  @impl Parser
  def file_names(), do: ["yarn.lock"]

  # yarn_parser reads both the classic v1 format and the YAML lockfile of
  # yarn 2+ (berry), and splits multi-spec keys ("a@^1, a@^1.1") into one
  # entry per spec.
  defp decode!(content) do
    case YarnParser.decode(content) do
      {:ok, %YarnParser.YarnLock{dependencies: deps}} -> deps
      {:error, reason} -> raise ArgumentError, "cannot parse yarn.lock: #{reason}"
    end
  end

  # A workspace package (linkType soft) is the project itself, not a dependency.
  defp package_version({_spec, %{"linkType" => "soft"}}), do: []

  defp package_version({spec, %{"version" => version}}) do
    case package_name(spec) do
      nil -> []
      name -> [{name, to_string(version)}]
    end
  end

  defp package_version(_), do: []

  # "@babel/core@^7.0.0" -> "@babel/core", "lodash@npm:^4.17.0" -> "lodash".
  # The name ends at the first "@" after its first character, so a scope's
  # leading "@" stays part of it.
  defp package_name(spec) do
    case Regex.run(~r/^(@?[^@]+)@/, spec, capture: :all_but_first) do
      [name] -> name
      nil -> nil
    end
  end

  defp newer_version(a, b) do
    if compare_versions(a, b) == :lt, do: b, else: a
  end

  defp compare_versions(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb)
      _ -> compare_segments(segments(a), segments(b))
    end
  end

  # Fallback for versions that are not semver ("1.0"): compare the numeric
  # segments as integers, so "1.10" is newer than "1.9".
  defp segments(version) do
    version
    |> String.split(~r/[^0-9]+/, trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  defp compare_segments(a, b) when a < b, do: :lt
  defp compare_segments(a, b) when a > b, do: :gt
  defp compare_segments(_, _), do: :eq
end
