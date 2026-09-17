defmodule Lei.StripeWebhookHandler do
  require Logger
  alias Lei.{Repo, Org}

  @doc """
  Applies a verified event once.

  The event id is recorded in the same transaction as the event's effects, so
  an event is applied and recorded, or neither. A redelivery -- Stripe delivers
  at least once, and a signed delivery can be captured and resent within the
  signature's tolerance -- finds the record and is skipped.

  Returns `{:ok, :processed}`, `{:ok, :duplicate}` or `{:error, :missing_event_id}`.
  Anything the handler raises rolls back, so the delivery is not recorded and
  Stripe's retry is processed.
  """
  def process(%{"id" => id, "type" => type} = event) when is_binary(id) and id != "" do
    Repo.transaction(fn ->
      # The row count, not a struct: with on_conflict: :nothing, Repo.insert/2
      # returns {:ok, struct} whether or not a row was written.
      row = %{id: id, type: to_string(type), inserted_at: NaiveDateTime.utc_now(:second)}

      case Repo.insert_all(Lei.StripeEvent, [row], on_conflict: :nothing, conflict_target: :id) do
        {0, _} ->
          :duplicate

        {1, _} ->
          result = handle_event(event)
          Logger.info("Stripe webhook #{type} #{id}: #{inspect(outcome(result))}")
          result
      end
    end)
    |> case do
      {:ok, :duplicate} ->
        {:ok, :duplicate}

      # Counted only once the transaction has committed, so a delivery that
      # raised and will be retried is not counted twice.
      {:ok, {:reversal, result}} ->
        Lei.ReversalStats.record(result)
        {:ok, :processed}

      {:ok, _} ->
        {:ok, :processed}

      other ->
        other
    end
  end

  def process(_event), do: {:error, :missing_event_id}

  defp outcome({:ok, %Org{} = org}), do: {:ok, org.id}
  defp outcome(other), do: other

  # checkout.session.completed arrives for every finished checkout, paid or not:
  # an asynchronous payment method completes the session with payment_status
  # "unpaid" and settles later, as checkout.session.async_payment_succeeded.
  def handle_event(%{"type" => type} = event)
      when type in ["checkout.session.completed", "checkout.session.async_payment_succeeded"] do
    session = event["data"]["object"]
    org_id = get_in(session, ["metadata", "org_id"])

    cond do
      # Paid at Stripe while Pro checkout is switched off. Not applied, and not
      # recorded as processed: raising rolls the event back and answers 500, so
      # Stripe retries it (for up to three days) and it applies once the
      # switch is back on.
      not Lei.Payments.Switches.enabled?("pro_checkout") ->
        raise Lei.Payments.Switches.SwitchedOff, path: "pro_checkout"

      is_nil(org_id) ->
        Logger.warning("Stripe webhook: missing org_id in session metadata")
        {:error, :missing_org_id}

      session["payment_status"] not in ["paid", "no_payment_required"] ->
        {:ok, :not_paid}

      true ->
        activate_paid(Repo.get(Org, org_id), session)
    end
  end

  def handle_event(%{"type" => "customer.subscription.deleted"} = event) do
    subscription = event["data"]["object"]
    customer_id = subscription["customer"]

    case find_org_by_customer(customer_id) do
      nil ->
        Logger.warning("Stripe webhook: no org for customer #{customer_id}")
        {:error, :org_not_found}

      org ->
        org
        |> Org.stripe_changeset(%{status: "suspended"})
        |> Repo.update()
    end
  end

  def handle_event(%{"type" => "invoice.payment_failed"} = event) do
    invoice = event["data"]["object"]
    customer_id = invoice["customer"]

    case find_org_by_customer(customer_id) do
      nil ->
        Logger.warning("Stripe webhook: no org for customer #{customer_id}")
        {:error, :org_not_found}

      org ->
        Logger.warning("Stripe webhook: payment failed for org #{org.id}, suspending")

        org
        |> Org.stripe_changeset(%{status: "suspended"})
        |> Repo.update()
    end
  end

  # Money going back to a customer. See Lei.Payments.Reversals for why these
  # three and not refund.created or charge.dispute.created.
  def handle_event(%{"type" => "charge.refunded"} = event),
    do: reversal(event, &Lei.Payments.Reversals.refund/1)

  def handle_event(%{"type" => "charge.dispute.funds_withdrawn"} = event),
    do: reversal(event, &Lei.Payments.Reversals.dispute_withdrawn/1)

  def handle_event(%{"type" => "charge.dispute.funds_reinstated"} = event),
    do: reversal(event, &Lei.Payments.Reversals.dispute_reinstated/1)

  def handle_event(%{"type" => type}) do
    Logger.debug("Stripe webhook: ignoring event type #{type}")
    :ok
  end

  defp reversal(%{"type" => type, "data" => %{"object" => object}}, apply) do
    result = apply.(object)

    if result == :unmatched do
      Logger.warning(
        "Stripe webhook #{type}: no credit purchase for PaymentIntent #{inspect(object["payment_intent"])}; ledger unchanged"
      )
    end

    {:reversal, result}
  end

  defp activate_paid(nil, session) do
    Logger.warning("Stripe webhook: org #{get_in(session, ["metadata", "org_id"])} not found")
    {:error, :org_not_found}
  end

  # Never re-activates a suspended org: an old completion replayed after a
  # cancellation or a failed payment would otherwise undo the suspension.
  defp activate_paid(%Org{status: "suspended"} = org, _session) do
    Logger.warning("Stripe webhook: org #{org.id} is suspended; checkout completion ignored")
    {:ok, :suspended}
  end

  defp activate_paid(%Org{} = org, session) do
    attrs =
      %{
        status: "active",
        stripe_customer_id: session["customer"],
        stripe_subscription_id: session["subscription"]
      }
      |> maybe_put(:stripe_metered_subscription_item_id, extract_subscription_item_id(session))

    org
    |> Org.stripe_changeset(attrs)
    |> Repo.update()
  end

  defp find_org_by_customer(customer_id) when is_binary(customer_id) do
    import Ecto.Query
    Repo.one(from(o in Org, where: o.stripe_customer_id == ^customer_id))
  end

  defp find_org_by_customer(_), do: nil

  defp extract_subscription_item_id(%{"subscription_items" => %{"data" => [item | _]}}) do
    item["id"]
  end

  defp extract_subscription_item_id(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
