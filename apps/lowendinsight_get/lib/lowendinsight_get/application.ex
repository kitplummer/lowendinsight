# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.Application do
  use Application

  require Logger

  def start(_type, _args) do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(LowendinsightGet.Repo, fn repo ->
        Ecto.Migrator.run(repo, Ecto.Migrator.migrations_path(repo), :up, all: true)
      end)

    Supervisor.start_link(children(), opts())
  end

  defp children do
    redis_url = Application.get_env(:redix, :redis_url)
    Logger.info("REDIS_URL: #{redis_url}")

    uri = URI.parse(redis_url)

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

    ssl? = uri.scheme == "rediss"

    redix_opts = [
      name: :redix,
      sync_connect: false,
      exit_on_disconnection: false,
      host: uri.host,
      port: port,
      password: password
    ]

    redix_opts = if ssl?, do: redix_opts ++ [ssl: true], else: redix_opts

    kids = [
      {Redix, {redis_url, redix_opts}},
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
