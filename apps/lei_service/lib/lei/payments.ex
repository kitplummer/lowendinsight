defmodule Lei.Payments do
  @moduledoc """
  Two sides, each with pluggable rails. See ADR-002 Amendment 1.

  Money arrives in two fundamentally different shapes, and collapsing them into
  one interface makes both worse:

    * a **machine** pays inline, as part of the HTTP exchange that asks for the
      work. There is no browser, no redirect, no human to approve anything. The
      server answers 402 with payment requirements and the agent retries with
      proof.

    * a **human** pays out of band, through a hosted checkout, and the outcome
      arrives later as a webhook. The request that triggered it is long gone.

  So there are two behaviours, `Lei.Payments.MachineRail` and
  `Lei.Payments.HumanRail`, and adapters behind each.

  ## Why adapters rather than an implementation

  This market is about six months old and has already invalidated one decision
  in ADR-002: the settlement-granularity reasoning assumed a chain transaction
  on the request path, which MPP's streaming cadence removes. It will be wrong
  again. The structure that survives that is one where a rail is a module, not
  a set of assumptions spread through the request path.

  Concretely, a rail may only do three things: describe what payment it wants,
  verify a settlement, and name it. Everything else -- what a credit is worth,
  when it is debited, what the balance means -- belongs to the ledger and is
  the same regardless of how the money arrived.

  ## The naming matters most

  `settlement_ref/1` becomes `credit_entries.external_ref`, which carries a
  unique index. That index is the only thing standing between us and
  double-crediting a replayed webhook or a resubmitted payment proof --
  duplicate settlement under concurrency being both a documented x402 attack
  class and the failure this codebase keeps meeting. A rail that cannot produce
  a stable, unique reference for a settlement cannot be integrated safely.
  """

  alias Lei.{CreditEntry, Credits}

  @doc """
  The rail names the ledger will accept.

  Derived from `Lei.CreditEntry`'s reason whitelist rather than kept as a
  second list, so the two cannot drift.
  """
  def known_rails do
    CreditEntry.reasons()
    |> Enum.filter(&String.starts_with?(&1, "purchase:"))
    |> Enum.map(&String.replace_prefix(&1, "purchase:", ""))
  end

  @doc """
  Raises unless every configured rail can actually write to the ledger.

  The reason whitelist is a good safeguard and it fires at insert time -- after
  the rail has verified a real settlement. A typo in a rail's `name/0` would
  therefore surface as: payment accepted, credits refused, and because the
  insert is rejected, no ledger record of any of it.

  Called at boot so a misnamed rail fails before it can take money, not after.
  """
  def validate_rails!(rails \\ configured_rails()) do
    unknown =
      rails
      |> Enum.map(& &1.name())
      |> Enum.reject(&(&1 in known_rails()))

    if unknown != [] do
      raise ArgumentError, """
      Payment rails #{inspect(unknown)} are not in Lei.CreditEntry's reason whitelist.

      A rail whose name the ledger will not accept can verify a payment and then
      fail to record it, leaving money taken and no entry to find it by.

      Known rails: #{inspect(known_rails())}
      """
    end

    Enum.each(rails, &validate_cadences!/1)

    :ok
  end

  @cadences [:one_shot, :recurring, :streaming]

  def cadences, do: @cadences

  defp validate_cadences!(rail) do
    declared = rail.cadences()

    cond do
      declared == [] ->
        raise ArgumentError,
              "#{inspect(rail)} declares no cadences, so nothing can ever be bought through it."

      (bad = declared -- @cadences) != [] ->
        raise ArgumentError,
              "#{inspect(rail)} declares unknown cadences #{inspect(bad)}. Known: #{inspect(@cadences)}"

      # A rail that streams settles per interaction, so a minimum purchase is a
      # contradiction: there is nothing to take a minimum of.
      :streaming in declared and rail.minimum_purchase_credits() != nil ->
        raise ArgumentError, """
        #{inspect(rail)} declares :streaming and a minimum purchase of         #{rail.minimum_purchase_credits()} credits.

        Streaming settles per interaction, so there is no purchase to apply a
        minimum to. Either the rail sells blocks or it streams.
        """

      true ->
        :ok
    end
  end

  defp configured_rails do
    Application.get_env(:lowendinsight, :payment_rails, [])
  end

  @doc """
  Credits a settled payment to an org.

  The single point where every rail, on either side, meets the ledger. Rails do
  not write credit entries themselves: there is one idempotency boundary and it
  lives here.

  Returns `{:error, :duplicate}` when this settlement was already credited,
  which is an expected outcome of a retry and not a failure.
  """
  def credit_settlement(org_id, %{credits: credits, rail: rail, settlement_ref: ref} = settlement)
      when is_integer(credits) and credits > 0 and is_binary(ref) do
    Credits.grant(org_id, credits, "purchase:#{rail}",
      # Namespaced by rail. external_ref is globally unique, so two rails that
      # ever mint the same string -- a Stripe event id, an integer nonce, a
      # per-payer sequence -- would collapse into one another. And because
      # {:error, :duplicate} is documented as an expected retry outcome, a
      # caller following that contract would treat a real second payment as an
      # already-handled replay: money taken, no credits granted, and nothing in
      # an append-only ledger to find it by afterwards.
      #
      # This is the only writer of purchase refs, so namespacing costs no
      # migration today and will never be cheaper.
      external_ref: "#{rail}:#{ref}",
      # Value at receipt, which is not always the face value of the credits
      # granted. ADR-002's accounting section: storing only one makes the
      # difference unrecoverable.
      usd_value_cents: Map.get(settlement, :usd_value_cents),
      # Where the customer is, when a rail can say. The accounting section
      # treats this as load-bearing and the boundary was dropping it.
      jurisdiction: Map.get(settlement, :jurisdiction),
      metadata: settlement_metadata(settlement)
    )
  end

  @doc """
  Takes credits back when a rail reverses a settlement.

  Refunds, chargebacks and cancelled authorisations all happen, on every rail.
  The ledger is append-only, so a reversal is a new negative entry rather than
  an edit -- "how did this balance get here" stays answerable, and the original
  purchase stays visible alongside what undid it.

  Deliberately allowed to take a balance negative. An org that spent credits
  and then charged back has a real debt, and refusing to record it would lose
  the fact rather than prevent it.

  Idempotent on the same reversal reference, by the same unique index that
  protects the purchase.
  """
  def reverse_settlement(org_id, %{credits: credits, rail: rail, settlement_ref: ref} = reversal)
      when is_integer(credits) and credits > 0 and is_binary(ref) do
    Credits.debit(org_id, credits, "reversal:#{rail}",
      # Namespaced twice: by rail, and as a reversal. A refund often carries
      # the id of the payment it reverses, so without the second namespace a
      # refund and its original purchase would collide on external_ref and the
      # refund would be silently swallowed as a duplicate.
      external_ref: "#{rail}:reversal:#{ref}",
      metadata:
        settlement_metadata(reversal)
        |> Map.put("reverses", Map.get(reversal, :reverses, ref))
    )
  end

  # A settlement was recording less than a debit does -- the debit path writes
  # four metadata fields. For the entry an audit would actually need to trace
  # back to a payer, that is backwards.
  defp settlement_metadata(settlement) do
    %{"rail" => settlement.rail, "rail_ref" => settlement.settlement_ref}
    |> maybe_put("payer", Map.get(settlement, :payer))
    |> maybe_put("settled_at", Map.get(settlement, :settled_at))
    # Relates settlements that came from one authorisation, which MPP's
    # streaming cadence produces many of.
    |> maybe_put("authorization_ref", Map.get(settlement, :authorization_ref))
    # What was actually paid, which is neither the credits granted nor the USD
    # value -- three different numbers, and only this one reconciles against
    # the rail's own records.
    |> maybe_put("asset", Map.get(settlement, :asset))
    |> maybe_put("amount", Map.get(settlement, :amount))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
