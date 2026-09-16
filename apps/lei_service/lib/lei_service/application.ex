# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LeiService.Application do
  use Application

  require Logger

  def start(_type, _args) do
    :ok = Lei.Boot.checks!()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(LeiService.Repo, fn repo ->
        Ecto.Migrator.run(repo, Ecto.Migrator.migrations_path(repo), :up, all: true)
      end)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Lei.Repo, fn repo ->
        Ecto.Migrator.run(repo, Ecto.Migrator.migrations_path(repo), :up, all: true)
      end)

    Supervisor.start_link(children(), opts())
  end

  defp children do
    # Must exist before any request is served; see RateLimiter.init_table/0 for
    # why it cannot be created in the plug's init/1.
    LeiService.Plugs.RateLimiter.init_table()

    # Created here, by a process that lives as long as the application. An ETS
    # table dies with the process that created it, and created lazily these
    # belonged to whichever request counted first -- so every webhook outcome
    # was deleted with its request, and /metrics read 0 in production.
    Lei.WebhookStats.init_table()
    Lei.ReversalStats.init_table()

    redis_url = Application.get_env(:redix, :redis_url)

    uri = URI.parse(redis_url)
    ssl? = uri.scheme == "rediss"

    password =
      if uri.userinfo do
        uri.userinfo |> String.split(":") |> Enum.at(1)
      end

    port = uri.port || 6379
    host = uri.host || "localhost"

    database =
      case uri.path do
        "/" <> db when db != "" -> String.to_integer(db)
        _ -> 0
      end

    # Redix defaults to socket_opts: [:inet] (IPv4). Fly's private network is
    # IPv6-only, so without :inet6 the connection never establishes and every
    # command returns %Redix.ConnectionError{reason: :closed} -- which reads as
    # a server-side close but actually means "never connected". The Postgres
    # config alongside this has always set socket_options: [:inet6]; Redis was
    # simply missing the equivalent.
    socket_opts = Application.get_env(:lei_service, :redis_socket_opts, [])

    redix_opts =
      [
        name: :redix,
        sync_connect: false,
        exit_on_disconnection: false,
        host: host,
        port: port,
        password: password,
        ssl: ssl?,
        database: database,
        socket_opts: socket_opts
      ]

    Logger.info(
      "Redix opts (sans password): host=#{host} port=#{port} db=#{database} " <>
        "ssl=#{ssl?} socket_opts=#{inspect(socket_opts)}"
    )

    kids =
      [{Redix, redix_opts}] ++
        Lei.Boot.children() ++
        [
          LeiService.Repo,
          {Oban, Application.fetch_env!(:lei_service, Oban)},
          LeiService.RequestLogger,
          LeiService.Endpoint,
          {Task.Supervisor, name: LeiService.AnalysisSupervisor}
        ]

    # Scheduled work is Oban cron now (ADR-004); :cache_clean_enable is read by
    # LeiService.CacheCleanerWorker, not by a supervised scheduler.
    kids
  end

  defp opts do
    [
      strategy: :one_for_one,
      name: LeiService.Supervisor
    ]
  end
end
