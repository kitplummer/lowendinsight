defmodule Lei.Web.BatchUnqueuedRefundTest do
  @moduledoc """
  A dependency that could not be queued is not paid for (#217).

  A batch is charged at admission, for every cache miss, before any job exists
  (#152 -- responses do not carry cache counts, so billing from them made async
  and timed-out requests free). The jobs are then inserted through Oban.

  Those two writes cannot share a transaction. `Lei.Repo` holds the ledger and
  `LeiService.Repo` is Oban's; they are separate Ecto repos with separate
  connection pools, so Ecto cannot span them -- in production they even address
  the same database, and it still cannot. So the money has to follow the work
  afterwards rather than atomically with it.

  The batch response already reported `summary.failed`, so the caller could see
  that a dependency was not queued. What it could not see was that it had paid
  for it anyway. The ledger now agrees with the response: a compensating
  `adjustment:unqueued` entry gives back exactly the credits for the
  dependencies that did not make it into the queue.

  This is a credit, not a reversal. `reversal:*` belongs to a rail undoing a
  purchase; nothing was purchased here and no rail is involved.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Repo}

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.BatchCache.clear()
    Lei.RateLimiter.clear()

    saved = Application.get_env(:lei_service, :batch_scheduler)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:lei_service, :batch_scheduler),
        else: Application.put_env(:lei_service, :batch_scheduler, saved)
    end)

    {:ok, org} =
      ApiKeys.find_or_create_org("Unqueued #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "k", ["analyze"])

    %{org: org, key: raw_key}
  end

  # The queue is the caller's to supply (ADR-004), so replacing it is how a
  # failure to enqueue is exercised without breaking Oban itself.
  defp scheduler(fun), do: Application.put_env(:lei_service, :batch_scheduler, fun)

  defp deps(n) do
    for i <- 1..n do
      %{
        "ecosystem" => "npm",
        "package" => "unqueued-#{System.unique_integer([:positive])}-#{i}",
        "version" => "1.0.0"
      }
    end
  end

  defp post_batch(key, dependencies) do
    conn(:post, "/v1/analyze/batch", Poison.encode!(%{"dependencies" => dependencies}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> Lei.Web.Router.call(@opts)
  end

  defp credits_by_reason(org_id) do
    org_id
    |> Credits.entries()
    |> Enum.group_by(& &1.reason, & &1.delta)
    |> Map.new(fn {reason, deltas} -> {reason, Enum.sum(deltas)} end)
  end

  test "the reason is one the ledger accepts" do
    assert "adjustment:unqueued" in Lei.CreditEntry.reasons()
  end

  test "credits come back for a dependency that could not be queued", ctx do
    scheduler(fn _dep -> {:error, :not_queued} end)

    conn = post_batch(ctx.key, deps(2))
    assert conn.status == 200

    body = Poison.decode!(conn.resp_body)
    assert body["summary"]["failed"] == 2

    by_reason = credits_by_reason(ctx.org.id)

    # Charged for two misses at admission, given both back: the org is level.
    assert by_reason["debit:analysis"] == -Credits.cost_in_credits(0, 2)
    assert by_reason["adjustment:unqueued"] == Credits.cost_in_credits(0, 2)
    assert Credits.balance(ctx.org.id) == 0
  end

  test "only the ones that failed are credited back", ctx do
    # The first is queued, the rest are not.
    counter = :counters.new(1, [])

    scheduler(fn _dep ->
      case :counters.get(counter, 1) do
        0 ->
          :counters.add(counter, 1, 1)
          {:ok, "job-1"}

        _ ->
          {:error, :not_queued}
      end
    end)

    conn = post_batch(ctx.key, deps(3))
    body = Poison.decode!(conn.resp_body)

    assert body["summary"]["pending"] == 1
    assert body["summary"]["failed"] == 2

    by_reason = credits_by_reason(ctx.org.id)

    assert by_reason["debit:analysis"] == -Credits.cost_in_credits(0, 3)
    assert by_reason["adjustment:unqueued"] == Credits.cost_in_credits(0, 2)

    # Net: paid for the one that was actually queued.
    assert Credits.balance(ctx.org.id) == -Credits.cost_in_credits(0, 1)
  end

  test "nothing is written when everything queues", ctx do
    scheduler(fn _dep -> {:ok, "job-ok"} end)

    conn = post_batch(ctx.key, deps(2))
    body = Poison.decode!(conn.resp_body)

    assert body["summary"]["failed"] == 0
    refute Map.has_key?(credits_by_reason(ctx.org.id), "adjustment:unqueued")
  end

  test "the response says what was given back, so the caller can reconcile", ctx do
    scheduler(fn _dep -> {:error, :not_queued} end)

    body = ctx.key |> post_batch(deps(2)) |> Map.fetch!(:resp_body) |> Poison.decode!()

    assert body["billing"]["unqueued"] == 2
    assert body["billing"]["credited_back_cents"] > 0
  end

  test "the entry records which org and how many, for an audit afterwards", ctx do
    scheduler(fn _dep -> {:error, :not_queued} end)

    post_batch(ctx.key, deps(2))

    entry =
      ctx.org.id
      |> Credits.entries()
      |> Enum.find(&(&1.reason == "adjustment:unqueued"))

    assert entry.metadata["unqueued"] == 2
    assert entry.external_ref =~ "unqueued:"
  end
end
