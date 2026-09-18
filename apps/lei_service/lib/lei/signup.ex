defmodule Lei.Signup do
  @moduledoc """
  Confirming a Pro checkout and issuing an org's first credentials.

  The success page used to activate whatever org the session cookie named. The
  cookie is set before the customer is sent to Stripe, so anyone could skip
  payment, request the success URL, and receive an active Pro org with an admin
  key. Here the only evidence of payment is the Checkout Session as Stripe
  reports it, fetched by id -- never anything the browser supplies about it.
  """
  import Ecto.Query

  alias Lei.{ApiKey, ApiKeys, Org, Repo}

  # "no_payment_required" is what a subscription with a free trial or a 100%
  # coupon completes with. Anything else -- "unpaid" in particular, which an
  # async payment method leaves behind until it settles -- waits for the
  # webhook.
  @settled ~w(paid no_payment_required)

  @doc """
  Activates `org` if `session_id` names a complete, paid Checkout Session that
  was created for it. Never re-activates a suspended org.
  """
  def confirm_paid_checkout(%Org{} = org, session_id) do
    with :ok <- present(session_id),
         {:ok, checkout} <- fetch(session_id),
         :ok <- for_org(checkout, org),
         :ok <- settled(checkout) do
      activate(org, checkout)
    end
  end

  @doc """
  Issues the org's admin key and recovery code, only if it has no keys yet.

  The org row is locked so two simultaneous visits cannot both see "no keys".
  """
  def issue_first_credentials(%Org{id: org_id}) do
    Repo.transaction(fn ->
      org = Repo.one!(from(o in Org, where: o.id == ^org_id, lock: "FOR UPDATE"))

      if Repo.exists?(from(k in ApiKey, where: k.org_id == ^org_id)) do
        Repo.rollback(:already_issued)
      else
        with {:ok, raw_key, _} <- ApiKeys.create_api_key(org, "admin", ["admin", "analyze"]),
             {:ok, recovery_code} <- ApiKeys.generate_recovery_code(org) do
          {org, raw_key, recovery_code}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  defp present(id) when is_binary(id) and id != "", do: :ok
  defp present(_), do: {:error, :no_session_id}

  defp fetch(session_id) do
    case Lei.Stripe.impl().retrieve_checkout_session(session_id) do
      {:ok, %{} = checkout} -> {:ok, checkout}
      {:error, _} -> {:error, :checkout_unavailable}
    end
  end

  defp for_org(checkout, org) do
    if get_in(checkout, ["metadata", "org_id"]) == to_string(org.id),
      do: :ok,
      else: {:error, :checkout_for_other_org}
  end

  defp settled(%{"status" => "complete", "payment_status" => status}) when status in @settled,
    do: :ok

  defp settled(_), do: {:error, :not_paid}

  defp activate(%Org{status: "suspended"}, _checkout), do: {:error, :suspended}
  defp activate(%Org{status: "active"} = org, _checkout), do: {:ok, org}

  defp activate(org, checkout) do
    # The billing address Checkout collected, in the same write that activates
    # them. Stripe asked the person for it; we never ask an agent (#223).
    location =
      checkout
      |> Lei.BuyerLocation.from_checkout()
      |> Org.usable_location_attrs()

    org
    |> Org.stripe_changeset(
      Map.merge(
        %{
          status: "active",
          stripe_customer_id: checkout["customer"],
          stripe_subscription_id: checkout["subscription"]
        },
        location
      )
    )
    |> Repo.update()
  end
end
