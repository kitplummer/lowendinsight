defmodule LeiService.ObanSchemaVersionTest do
  @moduledoc """
  The database's Oban schema is the one the installed Oban expects.

  The only Oban migration pinned `Oban.Migration.up(version: 12)`. Upgrading
  the oban package does not migrate the database, so production ran oban
  2.20.3 (schema 13) on schema 12 without its two state indexes, and nothing
  reported it. Oban 2.24's schema 14 adds the `suspended` job state; a job
  inserted in that state on schema 13 fails in Postgres.
  """
  use ExUnit.Case, async: true

  test "the migrated Oban schema matches the installed Oban" do
    migrated = Oban.Migrations.Postgres.migrated_version(repo: LeiService.Repo)
    expected = Oban.Migrations.Postgres.current_version()

    assert migrated > 0, "oban_jobs is not migrated at all; this test checked nothing"

    assert migrated == expected,
           "the database is at Oban schema #{migrated} but oban #{Application.spec(:oban, :vsn)} " <>
             "expects #{expected}: add a migration calling Oban.Migration.up(version: #{expected})"
  end

  test "the migrations bring the schema to the installed Oban's version" do
    # The database check above passes on any database migrated before a
    # migration was edited; this reads what a fresh database would get.
    dir = Ecto.Migrator.migrations_path(LeiService.Repo)

    versions =
      for file <- Path.wildcard(Path.join(dir, "*.exs")),
          [_, v] <- Regex.scan(~r/Oban\.Migration\.up\(version: (\d+)\)/, File.read!(file)),
          do: String.to_integer(v)

    assert versions != [], "no Oban migrations found in #{dir}; this test checked nothing"
    assert Enum.max(versions) == Oban.Migrations.Postgres.current_version()
  end
end
