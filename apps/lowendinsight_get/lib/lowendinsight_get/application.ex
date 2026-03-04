# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.Application do
  use Application

  require Logger

  def start(_type, _args) do
    {:ok, pid} = Supervisor.start_link(children(), opts())
    run_migrations()
    {:ok, pid}
  end

  defp run_migrations(retries \\ 10, delay \\ 2_000) do
    Ecto.Migrator.run(
      LowendinsightGet.Repo,
      Ecto.Migrator.migrations_path(LowendinsightGet.Repo),
      :up,
      all: true
    )
  rescue
    e ->
      if retries > 0 do
        Logger.warning("Database not ready, retrying in #{delay}ms... (#{retries} attempts left)")
        Process.sleep(delay)
        run_migrations(retries - 1, delay)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp children do
    Logger.info("REDIS_URL: #{Application.get_env(:redix, :redis_url)}")

    uri = URI.parse(Application.get_env(:redix, :redis_url))

    password =
      if uri.userinfo == nil do
        nil
      else
        uri.userinfo |> String.split(":") |> Enum.at(1)
      end

    port =
      if uri.port == nil do
        6379
      else
        uri.port
      end

    # Logger.info("HOST: #{uri.host}, P: #{port}, PW: #{password}")

    kids = [
      {Redix,
       {Application.get_env(:redix, :redis_url),
        [
          name: :redix,
          sync_connect: true,
          exit_on_disconnection: false,
          # socket_opts: [:inet6],
          host: uri.host,
          port: port,
          password: password
        ]}},
      LowendinsightGet.Repo,
      {Oban, Application.fetch_env!(:lowendinsight_get, Oban)},
      LowendinsightGet.Endpoint,
      {Task.Supervisor, name: LowendinsightGet.AnalysisSupervisor}
    ]

    kids =
      case Application.get_env(:lowendinsight_get, :cache_clean_enable) do
        true -> kids ++ [LowendinsightGet.Scheduler]
        false -> kids
      end

    kids
  end

  defp opts do
    [
      strategy: :one_for_one,
      name: LowendinsightGet.Supervisor
    ]
  end
end
