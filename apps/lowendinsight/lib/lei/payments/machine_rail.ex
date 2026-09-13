defmodule Lei.Payments.MachineRail do
  @moduledoc """
  A way for a machine to pay inline, as part of the HTTP exchange.

  Implemented by MPP first and x402 second -- see ADR-002 Amendment 1. Both use
  HTTP 402 and both build on EIP-3009 and Permit2, so the shape below is
  deliberately the intersection rather than either one's full surface.

  Adding a rail must not require touching the request path, the ledger, or the
  quota check. If it does, the boundary is in the wrong place.
  """

  @typedoc "What the caller must pay, serialised into the 402 response body."
  @type requirements :: map()

  @typedoc "Whatever the client returned as proof — a header value, usually."
  @type proof :: term()

  @typedoc """
  A verified payment. `credits` is what to grant; `settlement_ref` must be
  stable and unique for this settlement, because it is the idempotency
  boundary.
  """
  @type settlement :: %{
          required(:credits) => pos_integer(),
          # Which rail settled this. Part of the map rather than passed
          # alongside it, so a rail can hand its settlement straight to
          # Lei.Payments.credit_settlement/2 without the caller restating it.
          required(:rail) => String.t(),
          required(:settlement_ref) => String.t(),
          optional(:usd_value_cents) => non_neg_integer(),
          optional(:jurisdiction) => String.t(),
          optional(:payer) => String.t(),
          optional(:settled_at) => String.t(),
          # Ties settlements that came from one authorisation. MPP's streaming
          # cadence authorises a limit once and then settles repeatedly against
          # it, so a session produces many settlements rather than one. Without
          # this they are unrelatable, and reconciling our ledger against a
          # rail's own record of that session becomes guesswork.
          optional(:authorization_ref) => String.t(),
          # What was actually paid, as opposed to what it was worth in USD and
          # what we granted in credits. Three different numbers: 15,000 credits
          # might be 15.00 USDC or a card charge in another currency. Keeping
          # only the USD value loses the ability to reconcile against the rail.
          #
          # A string, because money in a float is money that drifts.
          optional(:asset) => String.t(),
          optional(:amount) => String.t()
        }

  @doc "Short name, used in the ledger reason as `purchase:<name>`."
  @callback name() :: String.t()

  @doc """
  What to put in a 402 for a caller that owes `credits`.

  Must not perform I/O that can fail slowly: this runs on the request path of
  a caller who has not paid, so it is reachable by anyone.
  """
  @callback requirements(credits :: pos_integer(), opts :: keyword()) ::
              {:ok, requirements()} | {:error, term()}

  @doc """
  Verifies a payment proof.

  A rail may return many settlements over its lifetime from a single
  authorisation -- that is what MPP's streaming cadence does. Each needs its
  own `settlement_ref`; `authorization_ref` is what relates them.

  Credits are granted only against money that has actually settled, never
  against an authorisation. An authorisation is a promise, and granting
  against it would put an unbacked balance in a ledger whose whole purpose is
  that the balance is explicable.

  Must be safe to call twice with the same proof. Returning a settlement does
  not credit anything — `Lei.Payments.credit_settlement/2` does, and the unique
  index on `credit_entries.external_ref`, which the settlement's
  `settlement_ref` becomes, is what makes a replay harmless.
  """
  @callback verify(proof(), opts :: keyword()) ::
              {:ok, settlement()} | {:error, term()}
end
