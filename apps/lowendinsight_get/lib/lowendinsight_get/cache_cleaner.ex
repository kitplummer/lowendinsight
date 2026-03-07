# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.CacheCleaner do
  require Logger

  def clean() do
    cache_ttl = Application.get_env(:lowendinsight_get, :cache_ttl, 2_592_000)
    Logger.info("SCHEDULER: TTL -> #{cache_ttl}")

    case Redix.start_link(Application.get_env(:redix, :redis_url)) do
      {:ok, conn} ->
        # Match both legacy URL keys (http*) and new structured keys (*:*:latest)
        Enum.each(["http*", "*:*:latest"], fn pattern ->
          case Redix.command(conn, ["KEYS", pattern]) do
            {:ok, keys} ->
              Enum.each(keys, fn key ->
                Logger.debug("key -> #{key}")
                check_ttl(conn, key)
              end)

            {:error, reason} ->
              Logger.warning("Redis KEYS #{pattern} failed: #{inspect(reason)}")
          end
        end)

        Redix.stop(conn)

      {:error, reason} ->
        Logger.warning("Redis connection failed during cache clean: #{inspect(reason)}")
    end
  end

  def check_ttl(conn, key, force_delete? \\ false) do
    case Redix.command(conn, ["GET", key]) do
      {:ok, nil} ->
        Logger.debug("#{key}: already gone")
        {:ok, nil}

      {:ok, json} ->
        value = Poison.decode!(json)

        if value["header"]["end_time"] != nil do
          cache_ttl = Application.get_env(:lowendinsight_get, :cache_ttl) * 86400
          report_time = get_report_time(value, force_delete?)

          if report_time >= cache_ttl do
            Logger.info("Deleting TTL expired key: #{key}")
            Redix.command(conn, ["DEL", key])
            :deleted
          end
        end

      {:error, reason} ->
        Logger.warning("Redis GET #{key} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_report_time(value, force_delete?) when force_delete? == false do
    value["header"]["end_time"] |> TimeHelper.get_commit_delta()
  end

  def get_report_time(_value, _force_delete?) do
    Application.get_env(:lowendinsight_get, :cache_ttl) * 86400
  end
end
