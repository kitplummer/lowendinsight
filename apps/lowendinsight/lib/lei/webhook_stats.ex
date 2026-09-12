defmodule Lei.WebhookStats do
  @moduledoc """
  Counts Stripe webhook verification outcomes so a broken signing secret is
  visible from outside the box.

  A wrong STRIPE_WEBHOOK_SECRET fails exactly like an unset one: every delivery
  gets a 400 and nothing else changes. That state went unnoticed once already
  -- the secret was set, webhooks were failing, and the only symptom was
  subscriptions quietly not activating.

  The three outcomes are deliberately distinct, because they need different
  responses:

    :ok            - verified
    :unconfigured  - Stripe signed it, we have no secret to check it with.
                     A deploy or secret-import problem.
    :invalid       - Stripe signed it, our secret disagrees. A rotation
                     problem: the endpoint's secret was rolled and Fly was not
                     updated, or was updated from the wrong endpoint.
    :unsigned      - no stripe-signature header at all. That is an internet
                     scanner hitting a public URL, not a Stripe failure, and it
                     must not raise an alarm.

  Counters live in ETS and reset when the node restarts. That is fine for the
  purpose: any non-zero :invalid or :unconfigured since the last restart is
  worth looking at.
  """

  @table :lei_webhook_stats
  @outcomes [:ok, :unconfigured, :invalid, :unsigned]

  def outcomes, do: @outcomes

  @doc """
  Creates the counter table if it does not exist.

  Called from record/1 rather than only at boot: a Plug's init/1 runs at compile
  time in a release, so anything set up there is absent at runtime. That mistake
  took down POST /v1/analyze for every authenticated caller once (#91).
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
