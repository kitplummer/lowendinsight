defmodule Lei.Payments.HumanRail do
  @moduledoc """
  A way for a person to pay, out of band, with the outcome arriving later.

  Stripe Billing is the implementation today. The behaviour exists so it is not
  the only possible one, and so the human side terminates in the same ledger as
  the machine side rather than in a parallel notion of what has been paid for.

  The asymmetry with `Lei.Payments.MachineRail` is real and not an oversight: a
  human payment is initiated in one request and settles in another, arriving as
  a webhook with no connection to the session that started it. Forcing both
  sides through one interface would mean pretending one of those shapes is the
  other.
  """

  @typedoc """
  A verified settlement.

  Close to the machine side's but not identical: this one carries `org_id`,
  because a webhook arrives with no request to infer it from, and has no
  `payer`, because the person is already an org. Both carry `rail`, so either
  can be handed straight to `Lei.Payments.credit_settlement/2`.
  """
  @type settlement :: %{
          required(:credits) => pos_integer(),
          required(:rail) => String.t(),
          required(:settlement_ref) => String.t(),
          required(:org_id) => pos_integer(),
          optional(:usd_value_cents) => non_neg_integer(),
          optional(:jurisdiction) => String.t(),
          optional(:settled_at) => String.t(),
          optional(:authorization_ref) => String.t(),
          optional(:asset) => String.t(),
          optional(:amount) => String.t()
        }

  @doc "Short name, used in the ledger reason as `purchase:<name>`."
  @callback name() :: String.t()

  @doc "A URL to send a person to in order to buy `credits`."
  @callback checkout(org_id :: pos_integer(), credits :: pos_integer(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Turns a verified provider event into a settlement, or `:ignore`.

  Signature verification happens before this: a rail is handed events it has
  already established are genuine. `:ignore` is for events that are real but
  not a purchase, which is most of them.
  """
  @callback handle_event(event :: map()) ::
              {:ok, settlement()} | :ignore | {:error, term()}
end
