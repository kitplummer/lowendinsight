defmodule Lei.Payments.Rails.Mpp do
  @moduledoc """
  The Machine Payments Protocol rail.

  Settles through Stripe: the agent presents a Shared Payment Token, we confirm
  a PaymentIntent with it, and Stripe charges the card or Link wallet behind it
  into the same balance our other revenue lands in. Stablecoin is a different
  MPP method (on-chain transfer to a deposit address) and is not this rail
  (#144). That is why this is the
  first adapter -- it puts machine income through the system that already
  handles tax calculation and reporting, which ADR-002's accounting section
  named as the one open item that can create liability retroactively.

  ## Cadence

  Declares `:one_shot` only.

  MPP *can* stream -- it authorises a limit once and settles repeatedly against
  it, and on Tempo that costs nothing per interaction, which is exactly the
  economics that make per-request settlement possible here and impossible on
  x402.

  It is not declared, because it is not implemented. There is no code path that
  settles repeatedly against one authorisation, and a cadence a rail announces
  but cannot perform is worse than one it does not offer: the boot check
  validates it, the interface advertises it, and the gap only appears when an
  agent tries to use it. `authorization_ref` exists on the settlement type
  ready for it.

  ## What this rail does not do

  Verification is Stripe's. We do not inspect chains, hold keys, or decide what
  counts as confirmed -- an RPC dependency, reorg handling and a confirmation
  policy are not where the value is, and each is a way to be wrong about money.
  """

  @behaviour Lei.Payments.MachineRail

  require Logger

  alias Lei.Payments.Mpp.{Challenge, Credential}

  # One credit is $0.001, so credits to cents is a divide by ten. Integer
  # arithmetic throughout: a rounding error here is a rounding error in money.
  @credits_per_cent 10

  @impl true
  def name, do: "mpp"

  @impl true
  def cadences, do: [:one_shot]

  # No minimum: a block is priced by whoever asks for the challenge, and this
  # rail settles through Stripe where the fee is proportional above the fixed
  # 30c. The router asks for 15,000 credits ($15), where that fixed part is
  # 4.9% rather than the 6000% it would be on a single cache hit.
  @impl true
  def minimum_purchase_credits, do: nil

  @doc """
  The charge in cents for a number of credits.

  Exposed because the 402 and the PaymentIntent must agree to the cent. If they
  disagree the agent authorises one figure and is charged another.
  """
  def cents_for(credits) when is_integer(credits) and credits > 0 do
    div(credits, @credits_per_cent)
  end

  @impl true
  def requirements(credits, opts \\ []) when is_integer(credits) and credits > 0 do
    cents = cents_for(credits)

    cond do
      cents < 1 ->
        # Below a cent there is nothing a payment network can charge, and a
        # zero-amount intent would settle for nothing and read as success.
        {:error, {:below_minimum_chargeable, credits}}

      is_nil(profile_id()) ->
        # SPTs are minted for a seller profile named in the challenge. Without
        # one, no client can produce a token this rail can charge, and the
        # challenge would look payable and fail at the wallet.
        {:error, {:unavailable, :no_stripe_profile}}

      true ->
        {:ok,
         Challenge.new(
           realm: Keyword.get(opts, :realm, realm()),
           method: "stripe",
           intent: "charge",
           expires: Keyword.get(opts, :expires, DateTime.add(DateTime.utc_now(), 300, :second)),
           description: "#{credits} LowEndInsight credits",
           request: %{
             # Strings, because the request is canonicalised and compared
             # byte-for-byte. A float rendering differently in two languages
             # would refuse a legitimate payment.
             "amount" => Integer.to_string(cents),
             "currency" => "usd",
             "credits" => credits,
             # The shape of Stripe's charge method (draft-stripe-charge-00, as
             # the reference server mppx emits it). networkId is the profile the
             # agent's wallet scopes its token to.
             "methodDetails" => %{
               "networkId" => profile_id(),
               "paymentMethodTypes" => ["card", "link"]
             }
           }
         )}
    end
  end

  @doc """
  The Stripe profile SPTs are granted to. `profile_test_...` in a sandbox,
  `profile_...` live; `Lei.Stripe.Mode` refuses a pairing with the other mode's key.
  """
  def profile_id do
    case Application.get_env(:lowendinsight, :stripe_profile_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @impl true
  def verify(credential, opts \\ [])

  def verify(%Credential{} = credential, opts) do
    with {:ok, issued} <- fetch_issued_challenge(opts),
         :ok <- check_not_expired(issued),
         :ok <- check_matches(credential, issued),
         {:ok, token} <- fetch_token(credential),
         {:ok, intent} <- create_intent(issued, token) do
      settlement(issued, intent, credential)
    end
  end

  def verify(_other, _opts), do: {:error, :not_a_credential}

  # The challenge a credential claims to answer must be one we issued, and the
  # caller supplies it. Trusting the credential's own copy would make the echo
  # check circular -- comparing the client's claim against itself.
  defp fetch_issued_challenge(opts) do
    case Keyword.get(opts, :challenge) do
      %Challenge{} = challenge -> {:ok, challenge}
      _ -> {:error, :no_issued_challenge}
    end
  end

  defp check_not_expired(challenge) do
    if Challenge.expired?(challenge), do: {:error, :challenge_expired}, else: :ok
  end

  defp check_matches(credential, issued) do
    if Credential.matches?(credential, issued) do
      :ok
    else
      # Cross-resource substitution: a real payment, for something else.
      Logger.warning("MPP credential echoed a challenge we did not issue (#{issued.id})")
      {:error, :challenge_mismatch}
    end
  end

  defp fetch_token(%Credential{payload: payload}) do
    case payload["spt"] || payload["payment_method"] || payload["token"] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_payment_token}
    end
  end

  defp create_intent(issued, token) do
    amount = String.to_integer(issued.request["amount"])

    case Lei.Stripe.impl().confirm_shared_payment_token(%{
           amount: amount,
           currency: issued.request["currency"],
           spt: token,
           # Per challenge and token: a retry of this payment reaches the intent
           # that already took the money; a different token is a different
           # payment. The reference server keys it the same way.
           idempotency_key: "mpp_#{issued.id}_#{token}",
           metadata: %{"challenge_id" => issued.id, "credits" => issued.request["credits"]}
         }) do
      # succeeded only. requires_capture is an authorisation -- funds held, not
      # taken -- and ADR-002 grants credits against settled money, never that.
      {:ok, %{"status" => "succeeded"} = intent} ->
        {:ok, intent}

      {:ok, %{"status" => "requires_action"}} ->
        # 3DS or similar. An agent cannot complete it, and saying so is more
        # use to it than a generic refusal.
        {:error, :payment_requires_action}

      {:ok, %{"status" => status}} ->
        # Anything not settled is not money. Treating "processing" as paid is
        # how a service gives away work for a payment that later fails.
        {:error, {:payment_not_settled, status}}

      {:ok, _} ->
        {:error, :payment_status_unknown}

      {:error, reason} ->
        {:error, {:payment_failed, reason}}
    end
  end

  defp settlement(issued, intent, credential) do
    received = intent["amount_received"] || intent["amount"]

    {:ok,
     %{
       credits: issued.request["credits"],
       rail: name(),
       # Stripe's own id. One of ours could differ between two attempts at a
       # single settlement, and this becomes the ledger's idempotency key.
       settlement_ref: intent["id"],
       usd_value_cents: received,
       asset: String.upcase(intent["currency"] || issued.request["currency"]),
       amount: format_amount(received),
       payer: credential.source,
       settled_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp format_amount(cents) when is_integer(cents),
    do: :erlang.float_to_binary(cents / 100, decimals: 2)

  defp format_amount(_), do: nil

  defp realm do
    Application.get_env(:lowendinsight, :lei_base_url, "http://localhost:4000")
    |> URI.parse()
    |> Map.get(:host)
    |> Kernel.||("localhost")
  end
end
