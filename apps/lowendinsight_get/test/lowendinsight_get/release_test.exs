defmodule LowendinsightGet.ReleaseTest do
  @moduledoc """
  Release tasks are invoked by fly.toml's release_command, where a mistake is
  only discovered mid-deploy. These cover the parts that can be checked without
  actually running migrations.
  """
  use ExUnit.Case, async: true

  alias LowendinsightGet.Release

  test "migrates Lei.Repo before LowendinsightGet.Repo" do
    repos = Release.repos()

    assert Lei.Repo in repos
    assert LowendinsightGet.Repo in repos

    # Order matters: Lei.Repo owns orgs and api_keys, which lowendinsight_get
    # reads through Lei.ApiKeys.
    assert Enum.find_index(repos, &(&1 == Lei.Repo)) <
             Enum.find_index(repos, &(&1 == LowendinsightGet.Repo))
  end

  test "exports the functions fly.toml's release_command calls" do
    # A typo here surfaces as a failed release rather than a failed build, so
    # assert the entrypoints exist with the arities the command uses.
    assert {:migrate, 0} in Release.__info__(:functions)
    assert {:rollback, 2} in Release.__info__(:functions)
    assert {:repos, 0} in Release.__info__(:functions)
  end

  test "release_command in fly.toml names a function that exists" do
    fly_toml = File.read!(Path.join([__DIR__, "..", "..", "..", "..", "fly.toml"]))

    assert fly_toml =~ "release_command"

    [_, call] = Regex.run(~r/release_command = "(.+)"/, fly_toml)
    assert call =~ "LowendinsightGet.Release.migrate()"
    assert call =~ "/opt/app/bin/lowendinsight_get eval"
  end
end
