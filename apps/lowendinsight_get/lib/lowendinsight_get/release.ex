defmodule LowendinsightGet.Release do
  @moduledoc """
  Release tasks, callable from the built release without Mix.

  Invoked by `fly.toml`'s `release_command`, so migrations run before a new
  version takes traffic:

      /opt/app/bin/lowendinsight_get eval 'LowendinsightGet.Release.migrate()'

  Deliberately not Fly-specific. A Helm `pre-upgrade` hook or a Zarf action can
  call the same function when the UDS work (#19) resumes -- which is why the
  logic lives here rather than inline in `fly.toml`.
  """
  require Logger

  @apps [:lowendinsight, :lowendinsight_get]

  @doc """
  Runs all pending migrations for every configured repo, in app order.

  `Lei.Repo` migrates first: it owns orgs and api_keys, which lowendinsight_get
  reads through `Lei.ApiKeys`.
  """
  def migrate do
    load()

    for repo <- repos() do
      Logger.info("migrating #{inspect(repo)}")

      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

      Logger.info("migrations complete for #{inspect(repo)}")
    end

    :ok
  end

  @doc """
  Rolls a single repo back to `version`. Manual recovery only -- deploys never
  roll back migrations automatically, because a rollback that drops a column is
  not something to trigger from an unattended pipeline.
  """
  def rollback(repo, version) do
    load()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc "Repos to migrate, in order. Exposed for inspection via `eval`."
  def repos do
    Enum.flat_map(@apps, &Application.fetch_env!(&1, :ecto_repos))
  end

  defp load do
    # Postgres connections may negotiate TLS, and eval does not start
    # applications for us.
    {:ok, _} = Application.ensure_all_started(:ssl)
    Enum.each(@apps, &Application.load/1)
  end
end
