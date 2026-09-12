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

  alias Lei.Credits

  @doc """
  Credits a settled payment to an org.

  The single point where every rail, on either side, meets the ledger. Rails do
  not write credit entries themselves: there is one idempotency boundary and it
  lives here.

  Returns `{:error, :duplicate}` when this settlement was already credited,
  which is an expected outcome of a retry and not a failure.
  """
  def credit_settlement(org_id, %{
        credits: credits,
        rail: rail,
        settlement_ref: ref,
        usd_value_cents: usd_value_cents
      })
      when is_integer(credits) and credits > 0 and is_binary(ref) do
    Credits.grant(org_id, credits, "purchase:#{rail}",
      external_ref: ref,
      # Value at receipt, which is not always the face value of the credits
      # granted. ADR-002's accounting section: storing only one makes the
      # difference unrecoverable.
      usd_value_cents: usd_value_cents
    )
  end
end
