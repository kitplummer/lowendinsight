defmodule Lei.Payments.Reversals do
  @moduledoc """
  Money that Stripe sends back to a customer comes out of the ledger (#208).

  Every credit purchase in the ledger is keyed to a Stripe PaymentIntent --
  `acp:pi_…` (reason `purchase:stripe`), `mpp:pi_…` and `tempo:pi_…` -- and
  every refund and dispute event names the PaymentIntent it concerns. That is
  the whole join.

  ## What moves the ledger

  The ledger follows money, not paperwork (ADR-002: credits are granted against
  settled money, so they are withdrawn against withdrawn money):

    * `charge.refunded` -- the charge's cumulative `amount_refunded`. Credits
      reversed are in proportion to the purchase's `usd_value_cents`, so a
      partial refund takes back a part, and the parts sum to the whole.
    * `charge.dispute.funds_withdrawn` -- Stripe has taken the disputed amount
      from the balance. Opening a dispute (`charge.dispute.created`) moves no
      money and changes nothing here.
    * `charge.dispute.funds_reinstated` -- the dispute was won and the money
      returned, so the credits the withdrawal took are given back.

  ## Invariants

    * A purchase is never reversed for more than it granted, whatever mix of
      refunds and disputes arrives, in whatever order.
    * Each event is idempotent twice over: by event id in
      `Lei.StripeWebhookHandler.process/1`, and here by computing what is still
      owed from the ledger rather than trusting the event to be new.
    * The org's row is locked first, so two events for one purchase processed
      at once each see what the other committed.
    * A reversal may take a balance negative. See
      `Lei.Payments.reverse_settlement/2`.

  Nothing here calls Stripe. Every function runs inside the webhook's
  transaction.
  """

  import Ecto.Query
  alias Lei.{CreditEntry, Credits, Org, Payments, Repo}

  # Every writer of a purchase entry, and the prefix it uses. Lei.Acp grants
  # under `acp:` with the reason purchase:stripe; the machine rails go through
  # Payments.credit_settlement/2, which prefixes with the rail name.
  @purchase_prefixes ~w(acp mpp tempo)

  @doc "A `charge.refunded` charge object."
  def refund(%{"payment_intent" => pi, "amount_refunded" => refunded} = charge)
      when is_binary(pi) and is_integer(refunded) do
    with_purchase(pi, charge["currency"], fn purchase ->
      owed = proportion(purchase, refunded)
      already = reversed(purchase, "refund")
      credits = min(owed - already, remaining(purchase))

      if credits > 0 do
        reverse(purchase, credits, "refund", "#{pi}:refund:#{refunded}", %{
          "amount_refunded_cents" => refunded,
          "charge" => charge["id"]
        })
      else
        :already_applied
      end
    end)
  end

  def refund(_charge), do: :unmatched

  @doc "A `charge.dispute.funds_withdrawn` dispute object."
  def dispute_withdrawn(%{"id" => du, "payment_intent" => pi, "amount" => amount} = dispute)
      when is_binary(du) and is_binary(pi) and is_integer(amount) do
    with_purchase(pi, dispute["currency"], fn purchase ->
      credits = min(proportion(purchase, amount), remaining(purchase))

      cond do
        withdrawal(purchase, du) != nil ->
          :already_applied

        credits > 0 ->
          reverse(purchase, credits, "dispute", "#{pi}:dispute:#{du}", %{
            "dispute" => du,
            "disputed_cents" => amount
          })

        true ->
          :already_applied
      end
    end)
  end

  def dispute_withdrawn(_dispute), do: :unmatched

  @doc "A `charge.dispute.funds_reinstated` dispute object."
  def dispute_reinstated(%{"id" => du, "payment_intent" => pi} = dispute)
      when is_binary(du) and is_binary(pi) do
    with_purchase(pi, dispute["currency"], fn purchase ->
      ref = "#{purchase.rail}:reinstatement:#{pi}:dispute:#{du}"

      case withdrawal(purchase, du) do
        # Nothing was taken for this dispute, so there is nothing to give back.
        nil ->
          :already_applied

        %CreditEntry{delta: delta} ->
          if Repo.exists?(from(e in CreditEntry, where: e.external_ref == ^ref)) do
            :already_applied
          else
            {:ok, _} =
              Credits.grant(purchase.org_id, -delta, "reinstatement:#{purchase.rail}",
                external_ref: ref,
                metadata: %{
                  "rail" => purchase.rail,
                  "kind" => "reinstatement",
                  "reverses" => pi,
                  "dispute" => du
                }
              )

            :applied
          end
      end
    end)
  end

  def dispute_reinstated(_dispute), do: :unmatched

  # -- internals

  defp with_purchase(pi, currency, fun) do
    refs = Enum.map(@purchase_prefixes, &"#{&1}:#{pi}")

    entry =
      Repo.one(
        from(e in CreditEntry,
          where: e.external_ref in ^refs and like(e.reason, "purchase:%")
        )
      )

    cond do
      is_nil(entry) ->
        :unmatched

      # Every purchase so far is in USD cents. A purchase with no USD value, or
      # money in another currency, has no defined proportion; guessing one is
      # how a ledger drifts from Stripe without anything noticing.
      not (is_integer(entry.usd_value_cents) and entry.usd_value_cents > 0) or
          (currency || "usd") != "usd" ->
        :unmatched

      true ->
        # Serialises every event for this org's purchases, and anything else
        # that changes its balance under the same lock (Lei.UsageTracker).
        Repo.one!(from(o in Org, where: o.id == ^entry.org_id, lock: "FOR UPDATE"))

        fun.(%{
          org_id: entry.org_id,
          pi: pi,
          rail: String.replace_prefix(entry.reason, "purchase:", ""),
          credits: entry.delta,
          cents: entry.usd_value_cents
        })
    end
  end

  # Integer arithmetic, rounded down, capped at the purchase. A full refund is
  # exactly the credits granted, because cents == purchase.cents.
  defp proportion(purchase, cents) do
    min(div(purchase.credits * cents, purchase.cents), purchase.credits)
  end

  defp entries_for(purchase) do
    from(e in CreditEntry,
      where:
        e.org_id == ^purchase.org_id and fragment("?->>'reverses'", e.metadata) == ^purchase.pi
    )
  end

  # Credits taken back for this purchase by one kind of reversal.
  defp reversed(purchase, kind) do
    purchase
    |> entries_for()
    |> where([e], like(e.reason, "reversal:%") and fragment("?->>'kind'", e.metadata) == ^kind)
    |> select([e], coalesce(sum(e.delta), 0))
    |> Repo.one()
    |> to_integer()
    |> Kernel.-()
  end

  # What is still reversible: the purchase less everything taken back, plus
  # anything reinstated.
  defp remaining(purchase) do
    net =
      purchase
      |> entries_for()
      |> where([e], like(e.reason, "reversal:%") or like(e.reason, "reinstatement:%"))
      |> select([e], coalesce(sum(e.delta), 0))
      |> Repo.one()
      |> to_integer()

    max(purchase.credits + net, 0)
  end

  defp withdrawal(purchase, du) do
    Repo.one(
      from(e in CreditEntry,
        where: e.external_ref == ^"#{purchase.rail}:reversal:#{purchase.pi}:dispute:#{du}"
      )
    )
  end

  defp reverse(purchase, credits, kind, ref, metadata) do
    {:ok, _} =
      Payments.reverse_settlement(purchase.org_id, %{
        credits: credits,
        rail: purchase.rail,
        settlement_ref: ref,
        reverses: purchase.pi,
        kind: kind,
        extra: metadata
      })

    :applied
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
end
