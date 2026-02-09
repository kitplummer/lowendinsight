# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Cargo.Scanner do
  require HTTPoison.Retry

  @moduledoc """
  Scanner scans for Cargo/Rust dependencies to run analysis on.
  """

  @crates_io_api "https://crates.io/api/v1/crates"

  def scan(cargo?, _project_types) when cargo? == false, do: {[], 0}

  @doc """
  scan: takes in project types map with cargo paths and returns the
  dependencies mapped to their analysis and the number of dependencies.
  """
  @spec scan(boolean(), map()) :: {[any], non_neg_integer}
  def scan(_cargo?, %{cargo: cargo_paths}) do
    # Find Cargo.toml and Cargo.lock paths
    {cargo_toml, cargo_lock} = find_cargo_files(cargo_paths)

    # Parse dependencies from Cargo.toml
    {:ok, {_deps, deps_count}} =
      case cargo_toml do
        nil -> {:ok, {[], 0}}
        path -> File.read!(path) |> Cargo.Cargofile.parse!()
      end

    # Parse locked dependencies from Cargo.lock for exact versions
    packages =
      case cargo_lock do
        nil -> []
        path ->
          {:ok, {pkgs, _count}} = File.read!(path) |> Cargo.Cargolock.parse!()
          pkgs
      end

    # Analyze each dependency
    result_map =
      packages
      |> Enum.map(fn {_name, pkg} -> analyze_package(pkg) end)
      |> Enum.reject(&is_nil/1)

    {result_map, deps_count}
  end

  defp find_cargo_files(paths) do
    cargo_toml = Enum.find(paths, &String.ends_with?(&1, "Cargo.toml"))

    cargo_lock =
      case cargo_toml do
        nil -> nil
        toml_path ->
          lock_path = String.replace(toml_path, "Cargo.toml", "Cargo.lock")
          if File.exists?(lock_path), do: lock_path, else: nil
      end

    {cargo_toml, cargo_lock}
  end

  defp analyze_package(%{name: name, source_url: source_url} = _pkg) do
    repo_url = get_repo_url(name, source_url)

    case repo_url do
      nil -> nil
      url -> run_analysis(url, name)
    end
  end

  @doc """
  get_repo_url: Given a crate name and source info, determine the repository URL.
  For crates.io packages, queries the API. For git sources, uses the URL directly.
  """
  @spec get_repo_url(String.t(), term()) :: String.t() | nil
  def get_repo_url(name, {:git, %{url: url}}) do
    # Git dependency - use the URL directly
    url
  end

  def get_repo_url(name, {:crates_io, _}) do
    # Query crates.io API for repository URL
    query_crates_io(name)
  end

  def get_repo_url(name, nil) do
    # Local path dependency - try crates.io as fallback
    query_crates_io(name)
  end

  def get_repo_url(_name, _source) do
    # Unknown source type
    nil
  end

  defp query_crates_io(crate_name) do
    HTTPoison.start()

    {:ok, response} =
      HTTPoison.get(
        "#{@crates_io_api}/#{crate_name}",
        [{"User-Agent", "lowendinsight/1.0"}]
      )
      |> HTTPoison.Retry.autoretry(
        max_attempts: 3,
        wait: 5000,
        include_404s: false,
        retry_unknown_errors: false
      )

    case response.status_code do
      200 ->
        body = Poison.decode!(response.body)
        get_in(body, ["crate", "repository"])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp run_analysis(url, crate_name) do
    result = AnalyzerModule.analyze(url, "cargo.scan:#{crate_name}", %{types: true})

    case result do
      {:ok, report} -> report
      _ -> nil
    end
  end

  @doc """
  analyze_dependencies: Run LEI analysis on a list of dependencies.
  Returns list of analysis reports.
  """
  @spec analyze_dependencies([{atom(), map()}]) :: [map()]
  def analyze_dependencies(deps) do
    deps
    |> Enum.map(fn {_name, pkg} -> analyze_package(pkg) end)
    |> Enum.reject(&is_nil/1)
  end
end
