defmodule LeiService.Repo.Migrations.UpgradeObanJobsToV14 do
  @moduledoc """
  Brings the Oban schema to what oban 2.24 expects.

  The first Oban migration pinned version 12. Production then ran oban 2.20.3
  (schema 13) without schema 13's two state indexes. Schema 14 adds the
  `suspended` job state. ObanSchemaVersionTest fails when the database falls
  behind the installed Oban again.
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Back to schema 12, where the previous migration left it.
  def down, do: Oban.Migration.down(version: 13)
end
