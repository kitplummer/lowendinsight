defmodule Lei.AdmissionConcurrencyTest do
  @moduledoc """
  One balance, or one monthly allowance, is spent once however many requests
  arrive together.

  Admission read the balance (or the analyses remaining) and the debit was
  written after the analysis, by a fire-and-forget task. N requests arriving
  together all passed the check and all ran: a wallet org holding the price of
  one analysis was served N, and a free org with one analysis left ran N.
  Separately, the usage row was updated by read-then-write, so two writes for
  the same org could both read the same counters and one debit was lost.

  Admission now locks the org's row, checks, and records the usage and debit
  in one transaction (decided 2026-09-15: charged at admission; bad input is
  refused before it).

  These tests do not use the SQL sandbox. A shared sandbox connection runs one
  query at a time, which serialises exactly the interleaving under test, so a
  lock that did nothing would still pass. Each task takes its own connection,
  commits for real, and everything created is deleted afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.{ApiKeys, CreditEntry, Credits, Org, Repo, UsageTracker, Wallets}
  alias Lei.AnalysisUsage

  # The test pool has five connections; one is this process's.
  @concurrency 4

  # Rows here are committed, so they are deleted by id afterwards.
  @created {__MODULE__, :created_orgs}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :persistent_term.put(@created, [])

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      ids = :persistent_term.get(@created, [])
      Repo.delete_all(from(e in CreditEntry, where: e.org_id in ^ids))
      Repo.delete_all(from(u in AnalysisUsage, where: u.org_id in ^ids))
      Repo.delete_all(from(k in Lei.ApiKey, where: k.org_id in ^ids))
      Repo.delete_all(from(o in Org, where: o.id in ^ids))
      :persistent_term.erase(@created)
    end)

    :ok
  end

  defp track(org) do
    :persistent_term.put(@created, [org.id | :persistent_term.get(@created, [])])
    org
  end

  defp together(fun) do
    1..@concurrency
    |> Enum.map(fn _ ->
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        fun.()
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  defp wallet_org(balance) do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)
    track(org)
    if balance > 0, do: {:ok, _} = Credits.grant(org.id, balance, "adjustment:manual")
    org
  end

  defp free_org(remaining) do
    {:ok, org} =
      ApiKeys.create_org("Admission #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    track(org)
    limit = org.free_tier_analyses_limit

    if limit - remaining > 0,
      do: {:ok, _} = UsageTracker.record_usage(org.id, nil, limit - remaining, 0)

    org
  end

  test "a balance that covers one analysis admits exactly one of several at once" do
    miss = Credits.cost_in_credits(0, 1)
    org = wallet_org(miss)

    results = together(fn -> UsageTracker.admit_usage(org.id, nil, 0, 1, miss) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, {:insufficient_credits, _}}, &1)) ==
             @concurrency - 1

    assert Credits.balance(org.id) == 0
  end

  test "a free org with one analysis left admits exactly one of several at once" do
    org = free_org(1)

    results = together(fn -> UsageTracker.admit_usage(org.id, nil, 1, 0, 0) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    usage = UsageTracker.get_current_usage(org.id)
    assert usage.cache_hits + usage.cache_misses == org.free_tier_analyses_limit
  end

  test "simultaneous usage writes for one org lose nothing" do
    {:ok, org} =
      ApiKeys.create_org("Usage #{System.unique_integer([:positive])}",
        tier: "pro",
        status: "active",
        stripe_customer_id: "cus_test_c425fe2f"
      )

    track(org)

    together(fn -> UsageTracker.record_usage(org.id, nil, 1, 0) end)

    usage = UsageTracker.get_current_usage(org.id)
    assert usage.cache_hits == @concurrency

    debits =
      Repo.all(
        from(e in CreditEntry, where: e.org_id == ^org.id and e.reason == "debit:analysis")
      )

    assert length(debits) == @concurrency
    assert Credits.balance(org.id) == -@concurrency * Credits.cost_in_credits(1, 0)
  end
end
