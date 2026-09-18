defmodule Lei.Web.BatchAdmissionTest do
  @moduledoc """
  POST /v1/analyze/batch is admitted on what the batch will cost.

  It called the gate with no price at all, so the gate's only question was
  whether the org could start a request: a free org with one analysis left, or
  a wallet org holding a single credit, could submit a batch of any size and be
  billed for all of it afterwards.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, UsageTracker, Wallets}

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.BatchCache.clear()
    Lei.RateLimiter.clear()
    :ok
  end

  defp deps(n) do
    for _ <- 1..n do
      %{
        "ecosystem" => "npm",
        "package" => "batch-#{System.unique_integer([:positive])}",
        "version" => "1.0.0"
      }
    end
  end

  defp batch(deps, key) do
    conn(:post, "/v1/analyze/batch", Poison.encode!(%{"dependencies" => deps}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> Lei.Web.Router.call(@opts)
  end

  defp free_key(remaining) do
    {:ok, org} =
      ApiKeys.create_org("Batch Admission #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, _} = UsageTracker.record_usage(org.id, nil, 200 - remaining, 0)
    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "batch", ["analyze"])
    {org, raw_key}
  end

  defp used(org),
    do: UsageTracker.get_current_usage(org.id) |> then(&(&1.cache_hits + &1.cache_misses))

  test "a free org is refused a batch larger than its remaining analyses" do
    {org, key} = free_key(1)

    conn = batch(deps(5), key)

    assert conn.status == 402
    body = Poison.decode!(conn.resp_body)
    assert body["error"] == "free_tier_quota_exceeded"
    assert body["requested"] == 5

    Process.sleep(100)
    assert used(org) == 199
  end

  test "a free org is served a batch that fits" do
    {_org, key} = free_key(5)
    assert batch(deps(5), key).status == 200
  end

  test "a wallet org is asked to pay for a batch its balance does not cover" do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)
    {:ok, _} = Credits.grant(org.id, 1, "adjustment:manual")
    {:ok, key, _} = ApiKeys.create_api_key(org, "batch", ["analyze"])

    conn = batch(deps(5), key)

    assert conn.status == 402
    Process.sleep(100)
    assert Credits.balance(org.id) == 1
  end
end
