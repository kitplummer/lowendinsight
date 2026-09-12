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
          credits: pos_integer(),
          settlement_ref: String.t(),
          usd_value_cents: non_neg_integer() | nil,
          payer: String.t() | nil
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

  Must be safe to call twice with the same proof. Returning a settlement does
  not credit anything — `Lei.Payments.credit_settlement/2` does, and the unique
  index on `settlement_ref` is what makes a replay harmless.
  """
  @callback verify(proof(), opts :: keyword()) ::
              {:ok, settlement()} | {:error, term()}
end
