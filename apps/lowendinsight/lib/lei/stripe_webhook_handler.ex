defmodule Lei.StripeWebhookHandler do
  require Logger
  alias Lei.{Repo, Org}

  def handle_event(%{"type" => "checkout.session.completed"} = event) do
    session = event["data"]["object"]
    org_id = get_in(session, ["metadata", "org_id"])

    if org_id do
      case Repo.get(Org, org_id) do
        nil ->
          Logger.warning("Stripe webhook: org #{org_id} not found")
          {:error, :org_not_found}

        org ->
          subscription_id = session["subscription"]

          # Extract subscription_item_id if available in the session
          subscription_item_id = extract_subscription_item_id(session)

          attrs =
            %{
              status: "active",
              stripe_customer_id: session["customer"],
              stripe_subscription_id: subscription_id
            }
            |> maybe_put(:stripe_metered_subscription_item_id, subscription_item_id)

          org
          |> Org.stripe_changeset(attrs)
          |> Repo.update()
      end
    else
      Logger.warning("Stripe webhook: missing org_id in session metadata")
      {:error, :missing_org_id}
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

  def handle_event(%{"type" => type}) do
    Logger.debug("Stripe webhook: ignoring event type #{type}")
    :ok
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
