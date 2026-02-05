# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule FixtureHelper do
  @moduledoc """
  Helper functions for working with test fixture repositories.

  These fixtures are deterministic git repositories with known commit history,
  contributors, and file structures. Use these for unit tests that need to
  verify git-related functionality without network access.

  ## Available Fixtures

  * `simple_repo` - 3 commits, 1 contributor, 3 files
  * `multi_contributor_repo` - 6 commits, 3 contributors
  * `single_commit_repo` - 1 commit, 1 contributor
  * `elixir_project_repo` - Elixir project structure with mix.exs, mix.lock
  * `node_project_repo` - Node.js project with package.json
  * `python_project_repo` - Python project with requirements.txt

  ## Usage

      setup do
        FixtureHelper.ensure_fixtures_exist()
        {:ok, repo} = GitModule.get_repo(FixtureHelper.fixture_path(:simple_repo))
        {:ok, repo: repo}
      end
  """

  @fixtures_dir Path.join([__DIR__, "..", "fixtures", "repos"])

  @doc """
  Returns the absolute path to the fixtures directory.
  """
  def fixtures_dir do
    Path.expand(@fixtures_dir)
  end

  @doc """
  Returns the absolute path to a specific fixture repository.

  ## Examples

      iex> FixtureHelper.fixture_path(:simple_repo)
      "/path/to/test/fixtures/repos/simple_repo"
  """
  def fixture_path(fixture_name) when is_atom(fixture_name) do
    Path.join(fixtures_dir(), Atom.to_string(fixture_name))
  end

  @doc """
  Ensures all fixture repositories exist with their git history.
  Runs the setup script if fixtures are missing.
  """
  def ensure_fixtures_exist do
    simple_repo_git = Path.join(fixture_path(:simple_repo), ".git")

    unless File.exists?(simple_repo_git) do
      setup_fixtures()
    end

    :ok
  end

  @doc """
  Runs the fixture setup script to create/recreate all fixture repositories.
  """
  def setup_fixtures do
    script_path = Path.join(fixtures_dir(), "setup_fixtures.sh")

    if File.exists?(script_path) do
      {_output, 0} = System.cmd("bash", [script_path], cd: fixtures_dir())
      :ok
    else
      {:error, :script_not_found}
    end
  end

  @doc """
  Returns expected metadata for fixture repositories.
  Useful for writing deterministic assertions in tests.
  """
  def fixture_metadata(:simple_repo) do
    %{
      commit_count: 3,
      contributor_count: 1,
      contributors: ["Test Author <test@example.com>"],
      first_commit_date: "2024-01-01T10:00:00",
      last_commit_date: "2024-02-01T09:00:00"
    }
  end

  def fixture_metadata(:multi_contributor_repo) do
    %{
      commit_count: 6,
      contributor_count: 3,
      contributors: [
        "Alice Developer <alice@example.com>",
        "Bob Coder <bob@example.com>",
        "Carol Engineer <carol@example.com>"
      ],
      first_commit_date: "2024-01-01T10:00:00",
      last_commit_date: "2024-02-10T10:00:00"
    }
  end

  def fixture_metadata(:single_commit_repo) do
    %{
      commit_count: 1,
      contributor_count: 1,
      contributors: ["Solo Committer <solo@example.com>"],
      first_commit_date: "2024-01-15T12:00:00",
      last_commit_date: "2024-01-15T12:00:00"
    }
  end

  def fixture_metadata(:elixir_project_repo) do
    %{
      commit_count: 1,
      contributor_count: 1,
      project_type: :elixir,
      has_mix_exs: true,
      has_mix_lock: true
    }
  end

  def fixture_metadata(:node_project_repo) do
    %{
      commit_count: 1,
      contributor_count: 1,
      project_type: :node,
      has_package_json: true
    }
  end

  def fixture_metadata(:python_project_repo) do
    %{
      commit_count: 1,
      contributor_count: 1,
      project_type: :python,
      has_requirements_txt: true
    }
  end
end
