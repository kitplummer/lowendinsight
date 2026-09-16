defmodule Lei.ReversalStats do
  @moduledoc """
  Counts what happened to each Stripe refund and dispute event (#208).

  The ledger itself says what was reversed, durably, and `/metrics` reads that
  from `credit_entries`. What the ledger cannot say is what was *not* recorded:
  a refund Stripe made for a payment no purchase entry matches. That is either
  money that never bought credits (a Pro invoice) or a purchase the lookup
  failed to find, and from inside the handler the two look the same. Counting
  it is what makes the second visible instead of a quiet 200.

    :applied          - the ledger changed
    :already_applied  - a redelivery, or a later event describing money the
                        ledger has already accounted for
    :unmatched        - no credit purchase for this PaymentIntent

  Counters live in ETS and reset when the node restarts, like
  `Lei.WebhookStats`. Recorded only after the event's transaction commits.
  """

  @table :lei_reversal_stats
  @outcomes [:applied, :already_applied, :unmatched]

  def outcomes, do: @outcomes

  @doc """
  Creates the counter table if it does not exist.

  **Must be called at application start** (`LeiService.Application`). An ETS
  table is deleted when the process that created it exits; created from a
  request, it lasts as long as the request. The calls from record/1 and
  count/1 only keep a missing table from crashing the caller.
  """
  def init_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        Enum.each(@outcomes, &:ets.insert(@table, {&1, 0}))
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def record(outcome) when outcome in @outcomes do
    init_table()
    :ets.update_counter(@table, outcome, 1, {outcome, 0})
    :ok
  end

  def count(outcome) when outcome in @outcomes do
    init_table()

    case :ets.lookup(@table, outcome) do
      [{^outcome, n}] -> n
      [] -> 0
    end
  end

  def all, do: Map.new(@outcomes, &{&1, count(&1)})

  def reset do
    init_table()
    Enum.each(@outcomes, &:ets.insert(@table, {&1, 0}))
    :ok
  end
end
