defmodule LeiService.JobRefreshTest do
  @moduledoc """
  Polling an incomplete job refreshes it, and the refresh must not fail.

  `GET /v1/analyze/{uuid}` refreshes an incomplete job at most once per window
  (`JobAccessTest`), but every test there stubs the refresher. The real one
  re-queues the job's uncached URLs, and handed the queue the job's start time
  as the string it is stored as. With workers on, as in production, queueing
  formats it with `DateTime.to_iso8601/1`, which takes a `DateTime`: the first
  poll of every incomplete job in each window was a 500.

  Driven through the endpoint with the real refresher and workers on. Oban is
  `:manual` in tests, so queued work is inserted and never run.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    saved = {
      Application.get_env(:lei_service, :use_workers),
      Application.get_env(:lei_service, :job_refresher)
    }

    Application.put_env(:lei_service, :use_workers, true)
    Application.delete_env(:lei_service, :job_refresher)

    on_exit(fn ->
      {workers, refresher} = saved
      restore(:use_workers, workers)
      restore(:job_refresher, refresher)
      Lei.RateLimiter.clear()
    end)

    {:ok, org} =
      ApiKeys.create_org("Job Refresh #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, key, _} = ApiKeys.create_api_key(org, "k", ["analyze"])
    %{key: key}
  end

  defp restore(key, nil), do: Application.delete_env(:lei_service, key)
  defp restore(key, value), do: Application.put_env(:lei_service, key, value)

  defp authed(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  test "the first poll of an incomplete job answers the job, not a 500", %{key: key} do
    url = "https://github.com/kitplummer/job-refresh-#{System.unique_integer([:positive])}"

    started =
      conn(:post, "/v1/analyze", Poison.encode!(%{urls: [url], cache_mode: "async"}))
      |> put_req_header("content-type", "application/json")
      |> authed(key)
      |> LeiService.Endpoint.call(@opts)

    assert started.status == 200
    uuid = Poison.decode!(started.resp_body)["uuid"]
    on_exit(fn -> Redix.command(:redix, ["DEL", "job_refresh:" <> uuid]) end)

    polled = conn(:get, "/v1/analyze/" <> uuid) |> authed(key) |> LeiService.Endpoint.call(@opts)

    assert polled.status == 200, polled.resp_body
    assert %{"uuid" => ^uuid, "state" => "incomplete"} = Poison.decode!(polled.resp_body)
  end
end
