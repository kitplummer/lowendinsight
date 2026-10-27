# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule ProjectIdent do
  @moduledoc """
    ProjectIdent module
  """
  @doc """
  find_files: Traverses paths according to the given repository and project type
  and returns a list of matches
  """
  @spec find_files(atom | %{path: any}, atom | %{files: any, path: any}) :: [binary]
  def find_files(repo, project_type) do
    Path.wildcard(
      "#{repo.path}/#{project_type.path}/#{ProjectType.types_to_string(project_type)}"
    )
  end

  @doc """
  categorize_repo/1: takes in a Repository and will return a list
  of found project types within the repo.
  """
  def categorize_repo(repo, project_types) do
    Enum.reduce(project_types, %{}, fn project_type, acc ->
      search = find_files(repo, project_type)

      if Enum.empty?(search) do
        acc
      else
        Map.put(acc, project_type.name, search)
      end
    end)
  end

  @doc """
  get_project_types_identified: takes in a Repository and will return a list of maps
  of found project types within the repo.

  `exclude:` names directories, relative to the repository, whose manifests are
  left out. A directory, not a prefix: excluding `editor/e` leaves `editor/ext`
  in.
  """
  def get_project_types_identified(repo, opts \\ []) do
    ## Non-metric data about repo
    mix_type = %ProjectType{
      name: :mix,
      path: "",
      files: ["mix.exs,mix.lock"]
    }

    python_type = %ProjectType{
      name: :python,
      path: "**",
      files: ["*requirements.txt*"]
    }

    node_type = %ProjectType{
      name: :node,
      path: "**",
      files: ["package*.json", "yarn.lock"]
    }

    go_type = %ProjectType{
      name: :go_mod,
      path: "**",
      files: ["go.mod"]
    }

    cargo_type = %ProjectType{
      name: :cargo,
      path: "**",
      files: ["Cargo.toml"]
    }

    rubygem_type = %ProjectType{
      name: :rubygem,
      path: "**",
      files: ["Gemfile*,*.gemspec"]
    }

    maven_type = %ProjectType{
      name: :maven,
      path: "**",
      files: ["pom.xml"]
    }

    gradle_type = %ProjectType{
      name: :gradle,
      path: "**",
      files: ["build.gradle*"]
    }

    project_types = [
      mix_type,
      python_type,
      node_type,
      go_type,
      cargo_type,
      rubygem_type,
      maven_type,
      gradle_type
    ]

    repo = if is_map(repo) && Map.has_key?(repo, :__struct__), do: repo, else: %{path: repo}

    repo
    |> categorize_repo(project_types)
    |> Helpers.convert_config_to_list()
    |> without(repo.path, Keyword.get(opts, :exclude, []))
  end

  defp without(found, _root, []), do: found

  defp without(found, root, excluded) do
    prefixes = Enum.map(excluded, &(Path.expand(&1, Path.expand(root)) <> "/"))
    kept? = fn file -> not Enum.any?(prefixes, &String.starts_with?(Path.expand(file), &1)) end

    found
    |> Enum.map(fn {type, files} -> {type, Enum.filter(files, kept?)} end)
    |> Enum.reject(fn {_type, files} -> files == [] end)
    |> Map.new()
  end
end
