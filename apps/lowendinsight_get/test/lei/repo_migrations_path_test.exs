defmodule Lei.RepoMigrationsPathTest do
  @moduledoc """
  Lei.Repo finds its own migrations.

  When Lei.Repo moved from the library into this app (ADR-003), its migrations
  moved to priv/lei_repo. `priv:` was first passed to `use Ecto.Repo`, where
  Ecto ignores it, so the repo looked in priv/repo/migrations -- which holds
  only LowendinsightGet.Repo's Oban migration. Against a database that already
  had every table it reported "Migrations already up"; against an empty one it
  created nothing. Every test database was already migrated, so no test failed.
  Found by running the release's migrate command on an empty database.
  """
  use ExUnit.Case, async: true

  test "the migrations path is Lei.Repo's own, and holds its migrations" do
    path = Ecto.Migrator.migrations_path(Lei.Repo)

    assert String.ends_with?(path, "priv/lei_repo/migrations")

    files = Path.wildcard(Path.join(path, "*.exs"))
    assert length(files) >= 14
    assert Enum.any?(files, &String.ends_with?(&1, "_create_orgs.exs"))
  end

  test "LowendinsightGet.Repo does not also claim them" do
    refute Ecto.Migrator.migrations_path(LowendinsightGet.Repo) ==
             Ecto.Migrator.migrations_path(Lei.Repo)
  end
end
