defmodule LeiService.BatchEnqueueTest do
  @moduledoc """
  The batch endpoint queues the work it charges for.

  It reported every miss as "pending" with a generated id while enqueuing
  nothing (ADR-004 step 4).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.BatchCache.clear()
    Lei.RateLimiter.clear()

    secret = Application.get_env(:lei_service, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _} = Joken.generate_and_sign(%{}, operator_claims(), signer)
    %{token: jwt}
  end

  defp post_batch(token, dependencies) do
    conn(:post, "/v1/analyze/batch", Poison.encode!(%{"dependencies" => dependencies}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Lei.Web.Router.call(@opts)
  end

  defp queued_jobs do
    Ecto.Adapters.SQL.query!(
      LeiService.Repo,
      "SELECT worker, args->>'package' FROM oban_jobs ORDER BY id",
      []
    ).rows
  end

  test "each uncached dependency becomes one job, and its id is returned", %{token: token} do
    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "hex", "package" => "jason", "version" => "1.4.4"}
    ]

    conn = post_batch(token, deps)
    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)

    assert response["summary"]["pending"] == 2
    assert length(response["pending_jobs"]) == 2

    assert queued_jobs() == [
             ["LeiService.BatchDependencyWorker", "express"],
             ["LeiService.BatchDependencyWorker", "jason"]
           ]

    ids = Enum.map(queued_jobs_ids(), &to_string/1)
    assert Enum.sort(response["pending_jobs"]) == Enum.sort(ids)
  end

  defp queued_jobs_ids do
    Ecto.Adapters.SQL.query!(LeiService.Repo, "SELECT id FROM oban_jobs ORDER BY id", []).rows
    |> List.flatten()
  end

  test "a cached dependency is not queued again", %{token: token} do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})

    conn =
      post_batch(token, [%{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}])

    assert conn.status == 200
    assert Poison.decode!(conn.resp_body)["summary"]["cached"] == 1
    assert queued_jobs() == []
  end

  test "the same dependency twice queues one job", %{token: token} do
    dep = %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}

    post_batch(token, [dep])
    Lei.BatchCache.clear()
    post_batch(token, [dep])

    assert length(queued_jobs()) == 1
  end

  # An operator token needs an expiry now: one without it is refused, and one
  # too far out is too (Lei.OperatorToken).
  defp operator_claims do
    %{"exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}
  end
end
