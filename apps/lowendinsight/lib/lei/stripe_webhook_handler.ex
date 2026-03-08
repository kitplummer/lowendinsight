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
          org
          |> Org.stripe_changeset(%{
            status: "active",
            stripe_customer_id: session["customer"],
            stripe_subscription_id: session["subscription"]
          })
          |> Repo.update()
      end
    else
      Logger.warning("Stripe webhook: missing org_id in session metadata")
      {:error, :missing_org_id}
    end
  end

  def handle_event(%{"type" => type}) do
    Logger.debug("Stripe webhook: ignoring event type #{type}")
    :ok
  end
end
