# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Npm.Packagefile do
  @behaviour Parser

  @moduledoc """
    Provides package.json and package-lock.json dependency parser
  """

  @impl Parser
  def parse!(content) do
    deps =
      content
      |> Jason.decode()
      |> extract_deps()
      |> Enum.to_list()
      |> Enum.map(fn {dependency, info} ->
        if is_map(info) && Map.fetch!(info, "version"),
          do: {dependency, info["version"]},
          else: {dependency, List.last(String.split(info, ~r{[\^|~]}, parts: 2))}
      end)

    {:ok, {deps, length(deps)}}
  end

  @impl Parser
  def file_names(), do: ["package.json", "package-lock.json"]

  defp extract_deps({:ok, %{"dependencies" => deps, "devDependencies" => devDeps}}),
    do: Map.merge(deps, devDeps)

  defp extract_deps({:ok, %{"dependencies" => deps}}), do: deps

  defp extract_deps({:ok, %{"devDependencies" => devDeps}}), do: devDeps

  # lockfileVersion 3 (npm 7+) has no top-level "dependencies"; packages are
  # keyed by install path. Only top-level installs, as for version 1, and only
  # entries with a version -- a "link" to a local directory has none.
  defp extract_deps({:ok, %{"packages" => packages}}) do
    for {"node_modules/" <> name, %{"version" => version}} <- packages,
        not String.contains?(name, "/node_modules/"),
        into: %{},
        do: {name, %{"version" => version}}
  end

  defp extract_deps({:ok, %{}}), do: %{}
end
