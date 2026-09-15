# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Npm.Scanner do
  @moduledoc """
  Scanner scans for node dependencies to run analysis on.
  """

  @doc """
  scan: called when node? is false, returning an empty list and 0
  """
  def scan(node?, _project_types) when node? == false, do: {[], [], 0}

  @doc """
  scan: takes in a path to node dependencies and returns the
  dependencies mapped to their analysis and the number of dependencies
  """
  def scan(_node?, %{node: paths_to_npm_files}, option \\ ".") do
    path_to_package_json =
      Enum.find(paths_to_npm_files, &String.ends_with?(&1, "package#{option}json"))

    path_to_package_lock =
      Enum.find(paths_to_npm_files, &String.ends_with?(&1, "lock#{option}json"))

    path_to_yarn_lock = Enum.find(paths_to_npm_files, &String.contains?(&1, "yarn#{option}lock"))

    if path_to_package_json do
      {:ok, {direct_deps, deps_count}} =
        File.read!(path_to_package_json)
        |> Npm.Packagefile.parse!()

      cond do
        path_to_package_lock && path_to_yarn_lock ->
          {:ok, {json_lib_map, _count}} =
            File.read!(path_to_package_lock)
            |> Npm.Packagefile.parse!()

          json_result_map =
            Enum.map(json_lib_map, fn {lib, _version} ->
              query_npm(lib)
            end)

          {:ok, {yarn_lib_map, _count}} =
            File.read!(path_to_yarn_lock)
            |> Npm.Yarnlockfile.parse!()

          yarn_result_map =
            Enum.map(yarn_lib_map, fn {lib, _version} ->
              query_npm(lib)
            end)

          {json_result_map, yarn_result_map, deps_count}

        path_to_package_lock ->
          {:ok, {lib_map, _count}} =
            File.read!(path_to_package_lock)
            |> Npm.Packagefile.parse!()

          result_map =
            Enum.map(lib_map, fn {lib, _version} ->
              query_npm(lib)
            end)

          {result_map, [], deps_count}

        path_to_yarn_lock ->
          {:ok, {lib_map, _count}} =
            File.read!(path_to_yarn_lock)
            |> Npm.Yarnlockfile.parse!()

          result_map =
            Enum.map(lib_map, fn {lib, _version} ->
              query_npm(lib)
            end)

          {[], result_map, deps_count}

        true ->
          result_map =
            Enum.map(direct_deps, fn {lib, _version} ->
              query_npm(lib)
            end)

          {result_map, [], deps_count}
      end
    else
      {:error, "Must contain a package.json file"}
    end
  end

  @doc """
  query_npm: function that takes in a package and returns an analysis
  on that package's repository using analyser_module.  If the package url cannot
  be reached, an error is returned.
  """
  def query_npm(package) do
    target =
      case repository_url(package) do
        {:ok, url} -> url
        :none -> package
      end

    {:ok, report} = AnalyzerModule.analyze(target, "mix.scan", %{types: true})
    report
  end

  @registry "https://registry.npmjs.org/"

  @doc """
  repository_url: looks `package` up in the npm registry and returns
  `{:ok, url}` for its declared repository, or `:none` when the registry does
  not know it, it declares no repository, or the registry cannot be reached.
  `get` is the HTTP GET, replaceable in tests.
  """
  def repository_url(package, get \\ &HTTPoison.get/1) do
    url = @registry <> URI.encode(package)

    case Lei.HTTP.Retry.request(fn -> get.(url) end) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Poison.decode(body) do
          {:ok, %{"repository" => %{"url" => repo}}} when is_binary(repo) -> {:ok, repo}
          _ -> :none
        end

      _ ->
        :none
    end
  end
end
