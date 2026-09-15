defmodule LeiService.TrendingTriggerAuthTest do
  @moduledoc """
  Only an operator can force a trending refresh.

  POST /v1/gh_trending/process runs refresh_due(force: true) for every
  configured language: clones and analyses of every trending repository, the
  job that exhausted production's memory before (#158). Any API key -- a free
  signup's included -- could call it. The run lock stops runs overlapping, not
  a caller starting the next one the moment the last finishes (security
  review, 2026-09-14).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp trigger(auth) do
    conn(:post, "/v1/gh_trending/process")
    |> put_req_header("authorization", auth)
    |> LeiService.Endpoint.call(@opts)
  end

  for scopes <- [["analyze"], ["admin", "analyze"], ["cache"]] do
    test "an API key with #{inspect(scopes)} is refused" do
      {:ok, org} =
        ApiKeys.create_org("Trending Trigger #{System.unique_integer([:positive])}",
          tier: "pro",
          status: "active"
        )

      {:ok, key, _} = ApiKeys.create_api_key(org, "t", unquote(scopes))

      conn = trigger("Bearer " <> key)

      assert conn.status == 403
      refute conn.resp_body =~ "Processing"
    end
  end
end
