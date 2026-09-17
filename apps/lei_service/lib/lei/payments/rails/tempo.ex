defmodule Lei.Payments.Rails.Tempo do
  @moduledoc """
  MPP's `tempo` method: stablecoin, paid on-chain to a Stripe deposit address.

  The agent transfers USDC.e (pathUSD on testnet) to our deposit address with a
  memo we issued, and presents the transaction hash. Two questions, answered by
  two parties, because neither can answer both (#144):

    * **Whose payment is it?** The chain. Hashes are public, so a hash proves a
      payment happened, not that the presenter made it for this challenge. The
      memo is random per challenge; the receipt shows whether this transfer
      carries it, to our address, in our token, for our amount.
    * **Did the money arrive?** Stripe. A `transaction_verification`
      PaymentIntent verifies the transfer and settles it into our balance in
      USD. Credits wait for `succeeded` -- ADR-002 grants against settled
      money -- which in sandbox took under eight seconds.

  The chain read happens first, so nothing is created at Stripe for a
  credential that does not bind to its challenge.

  ## What this rail does not do

  Pull mode, where the server broadcasts a transaction the agent signed. That
  means decoding and fee-sponsoring Tempo transactions; `supportedModes` says
  `push` so a conforming client does not offer it.
  """

  @behaviour Lei.Payments.MachineRail

  require Logger

  alias Lei.Payments.Mpp.{Challenge, Credential}
  alias Lei.Tempo.{Network, Transfer}

  @credits_per_cent 10
  # Token units per cent: 6 decimals, so $0.01 is 10,000 units.
  @units_per_cent 10_000
  # Stripe refuses a crypto PaymentIntent under $0.50, although its docs give
  # 0.01 USDC (observed in sandbox, #144).
  @minimum_cents 50

  @impl true
  def name, do: "tempo"

  @impl true
  def cadences, do: [:one_shot]

  @impl true
  def minimum_purchase_credits, do: @minimum_cents * @credits_per_cent

  @impl true
  def requirements(credits, opts \\ []) when is_integer(credits) and credits > 0 do
    cents = div(credits, @credits_per_cent)
    network = Network.current()
    address = deposit_address()

    cond do
      cents < @minimum_cents ->
        {:error, {:below_minimum_chargeable, credits}}

      is_nil(network) ->
        {:error, {:unavailable, :stripe_not_configured}}

      is_nil(address) ->
        {:error, {:unavailable, :no_deposit_address}}

      # Real money sent to an address Stripe will not credit is gone. So no
      # challenge names an address until Stripe has confirmed, with this key,
      # that it is ours -- a sandbox address beside a live key would otherwise
      # take mainnet funds.
      not Keyword.get(opts, :confirmed?, &Lei.Stripe.ObjectCheck.deposit_address_confirmed?/1).(
        address
      ) ->
        {:error, {:unavailable, :deposit_address_unconfirmed}}

      true ->
        {:ok,
         Challenge.new(
           realm: Keyword.get(opts, :realm, realm()),
           method: "tempo",
           intent: "charge",
           expires: Keyword.get(opts, :expires, DateTime.add(DateTime.utc_now(), 300, :second)),
           description: "#{credits} LowEndInsight credits",
           request: %{
             "amount" => Integer.to_string(cents * @units_per_cent),
             "currency" => network.token,
             "recipient" => address,
             "credits" => credits,
             "methodDetails" => %{
               "chainId" => network.chain_id,
               "memo" => Keyword.get_lazy(opts, :memo, &new_memo/0),
               "supportedModes" => ["push"]
             }
           }
         )}
    end
  end

  @impl true
  def verify(credential, opts \\ [])

  def verify(%Credential{} = credential, opts) do
    with {:ok, issued} <- fetch_issued_challenge(opts),
         :ok <- check_not_expired(issued),
         :ok <- check_matches(credential, issued),
         {:ok, hash} <- fetch_hash(credential),
         {:ok, network} <- check_network(issued),
         {:ok, transfer} <- check_receipt(network, hash, issued),
         {:ok, intent} <- settle_with_stripe(hash, issued, opts) do
      {:ok, settlement(issued, intent, transfer)}
    end
  end

  def verify(_other, _opts), do: {:error, :not_a_credential}

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
      Logger.warning("Tempo credential echoed a challenge we did not issue (#{issued.id})")
      {:error, :challenge_mismatch}
    end
  end

  defp fetch_hash(%Credential{payload: %{"type" => "hash", "hash" => "0x" <> hex = hash}})
       when byte_size(hex) == 64 do
    if hex =~ ~r/\A[0-9a-fA-F]{64}\z/,
      do: {:ok, String.downcase(hash)},
      else: {:error, :no_transaction_hash}
  end

  defp fetch_hash(%Credential{payload: %{"type" => type}}) when type != "hash",
    do: {:error, {:unsupported_credential_type, type}}

  defp fetch_hash(_), do: {:error, :no_transaction_hash}

  # The mode could change between issuing a challenge and its answer -- a
  # cutover mid-exchange. A testnet challenge answered against mainnet (or the
  # reverse) must not be verified against the wrong chain.
  defp check_network(issued) do
    network = Network.current()

    if network && network.chain_id == get_in(issued.request, ["methodDetails", "chainId"]) do
      {:ok, network}
    else
      {:error, :network_changed}
    end
  end

  defp check_receipt(network, hash, issued) do
    expected = %{
      token: issued.request["currency"],
      recipient: issued.request["recipient"],
      memo: get_in(issued.request, ["methodDetails", "memo"]),
      amount: String.to_integer(issued.request["amount"])
    }

    case Lei.Tempo.Rpc.impl().get_transaction_receipt(network.rpc_url, hash) do
      {:ok, receipt} ->
        case Transfer.find_payment(receipt, expected) do
          # Exactly the amount asked. Stripe declines a mismatch as
          # invalid_amount, so accepting an overpayment here would pass the
          # chain check and fail at Stripe with the agent's money already sent.
          {:ok, %{amount: amount} = transfer} when amount == expected.amount -> {:ok, transfer}
          {:ok, _} -> {:error, :amount_mismatch}
          {:error, reason} -> {:error, {:transfer_not_bound, reason}}
        end

      {:error, :not_found} ->
        {:error, :transaction_not_found}

      {:error, reason} ->
        {:error, {:chain_unreachable, reason}}
    end
  end

  defp settle_with_stripe(hash, issued, opts) do
    cents = div(String.to_integer(issued.request["amount"]), @units_per_cent)

    params = %{
      amount: cents,
      network: "tempo",
      transaction_hash: hash,
      # One transfer, one intent. A retry of the same credential reaches the
      # intent already verifying it rather than a second one.
      idempotency_key: "tempo_#{hash}",
      metadata: %{"challenge_id" => issued.id, "credits" => issued.request["credits"]}
    }

    case Lei.Stripe.impl().create_crypto_verification_intent(params) do
      {:ok, %{"id" => id} = intent} ->
        await_settlement(id, intent, deadline(opts), opts)

      {:ok, _} ->
        {:error, :payment_status_unknown}

      # Stripe tracks each transfer in one PaymentIntent and refuses a second
      # (observed in sandbox, #144). Reaching this means the transfer was
      # verified under some other key -- not a retry of ours, which the
      # idempotency key returns to the original intent. Refused rather than
      # adopted: the intent it names is not one this exchange created.
      {:error, {400, %{"error" => %{"code" => "resource_already_exists"}}}} ->
        {:error, :transaction_already_verified}

      {:error, reason} ->
        {:error, {:payment_failed, reason}}
    end
  end

  defp await_settlement(_id, %{"status" => "succeeded"} = intent, _deadline, _opts),
    do: {:ok, intent}

  defp await_settlement(_id, %{"status" => "requires_payment_method"} = intent, _deadline, _opts) do
    decline = get_in(intent, ["last_payment_error", "decline_code"])
    {:error, {:payment_declined, decline}}
  end

  defp await_settlement(id, %{"status" => "processing"}, deadline, opts) do
    if System.monotonic_time(:millisecond) >= deadline do
      # Not a refusal of the payment: the agent retries the same credential
      # and reaches the same intent through the idempotency key.
      {:error, {:payment_not_settled, "processing"}}
    else
      Process.sleep(Keyword.get(opts, :poll_interval_ms, poll_interval_ms()))

      case Lei.Stripe.impl().retrieve_payment_intent(id) do
        {:ok, intent} -> await_settlement(id, intent, deadline, opts)
        {:error, reason} -> {:error, {:payment_failed, reason}}
      end
    end
  end

  defp await_settlement(_id, %{"status" => status}, _deadline, _opts),
    do: {:error, {:payment_not_settled, status}}

  defp await_settlement(_id, _intent, _deadline, _opts), do: {:error, :payment_status_unknown}

  defp deadline(opts) do
    System.monotonic_time(:millisecond) +
      Keyword.get(opts, :settle_timeout_ms, settle_timeout_ms())
  end

  defp settlement(issued, intent, transfer) do
    crypto = get_in(intent, ["latest_charge", "payment_method_details", "crypto"]) || %{}
    units = String.to_integer(issued.request["amount"])

    %{
      credits: issued.request["credits"],
      rail: name(),
      settlement_ref: intent["id"],
      usd_value_cents: intent["amount_received"],
      asset: String.upcase(crypto["token_currency"] || "usdc"),
      amount: format_units(units),
      # From the chain, where the memo binds it to this challenge and the
      # signer check has shown the holder authorised it. Stripe's
      # buyer_address agreed in every sandbox run, but it is not what was
      # checked.
      payer: transfer.from,
      settled_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp format_units(units) do
    whole = div(units, 1_000_000)
    frac = rem(units, 1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{whole}.#{frac}"
  end

  @impl true
  def payer_wallet(%{rail: "tempo", payer: "0x" <> hex = payer}) when byte_size(hex) == 40,
    do: String.downcase(payer)

  def payer_wallet(_settlement), do: nil

  # The agent broadcasts the transfer itself ("push" mode) and presents the hash
  # afterwards, so the money has moved before we see the credential.
  @impl true
  def funds_move_before_settlement?, do: true

  @doc "The configured deposit address, lowercased, or nil."
  def deposit_address do
    case Application.get_env(:lei_service, :tempo_deposit_address) do
      "0x" <> hex = address when byte_size(hex) == 40 -> String.downcase(address)
      _ -> nil
    end
  end

  defp new_memo, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp settle_timeout_ms,
    do: Application.get_env(:lei_service, :tempo_settle_timeout_ms, 20_000)

  defp poll_interval_ms, do: Application.get_env(:lei_service, :tempo_poll_interval_ms, 1_000)

  defp realm do
    Application.get_env(:lei_service, :lei_base_url, "http://localhost:4000")
    |> URI.parse()
    |> Map.get(:host)
    |> Kernel.||("localhost")
  end
end
