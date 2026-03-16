defmodule Lei.Acp do
  @moduledoc """
  ACP (Agentic Commerce Protocol) business logic for agent-to-agent commerce.
  Manages checkout session lifecycle: create → update → complete/cancel.
  """
  alias Lei.{Repo, AcpCheckoutSession, ApiKeys}

  @session_ttl_seconds 3600

  def create_session(sku) do
    amount = AcpCheckoutSession.amount_for_sku(sku)

    if is_nil(amount) do
      {:error, :invalid_sku}
    else
      id = "acp_cs_" <> UUID.uuid4()
      expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

      %AcpCheckoutSession{}
      |> AcpCheckoutSession.changeset(%{
        id: id,
        sku: sku,
        amount_cents: amount,
        expires_at: expires_at
      })
      |> Repo.insert()
    end
  end

  def get_session(id) do
    case Repo.get(AcpCheckoutSession, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  def update_session(id, attrs) do
    with {:ok, session} <- get_session(id),
         :ok <- check_session_open(session) do
      session
      |> AcpCheckoutSession.update_changeset(attrs)
      |> Repo.update()
    end
  end

  def complete_session(id, payment_params) do
    with {:ok, session} <- get_session(id),
         :ok <- check_session_open(session),
         :ok <- check_not_expired(session) do
      if session.amount_cents == 0 do
        complete_free_session(session)
      else
        complete_paid_session(session, payment_params)
      end
    end
  end

  def cancel_session(id) do
    with {:ok, session} <- get_session(id),
         :ok <- check_session_open(session) do
      session
      |> AcpCheckoutSession.update_changeset(%{status: "cancelled"})
      |> Repo.update()
    end
  end

  # --- Private ---

  defp check_session_open(%AcpCheckoutSession{status: "open"}), do: :ok
  defp check_session_open(_session), do: {:error, :session_not_open}

  defp check_not_expired(%AcpCheckoutSession{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :session_expired}
    end
  end

  defp complete_free_session(session) do
    customer_name = session.customer_name || "ACP Agent"

    with {:ok, org} <- ApiKeys.find_or_create_org(customer_name, tier: "free", status: "active"),
         {:ok, raw_key, _api_key} <-
           ApiKeys.create_api_key(org, "acp-key", ["admin", "analyze"]),
         {:ok, recovery_code} <- ApiKeys.generate_recovery_code(org) do
      session
      |> AcpCheckoutSession.update_changeset(%{status: "completed", org_id: org.id})
      |> Repo.update()

      {:ok,
       %{
         api_key: raw_key,
         recovery_code: recovery_code,
         org_slug: org.slug,
         tier: "free"
       }}
    end
  end

  defp complete_paid_session(session, payment_params) do
    stripe = Lei.Stripe.impl()
    payment_method = payment_params["payment_method"] || payment_params["shared_payment_token"]

    case stripe.create_payment_intent(%{
           amount: session.amount_cents,
           currency: session.currency,
           payment_method: payment_method
         }) do
      {:ok, %{"id" => pi_id, "status" => "succeeded"}} ->
        finalize_paid_session(session, pi_id)

      {:ok, %{"id" => pi_id, "status" => "requires_action"}} ->
        session
        |> AcpCheckoutSession.update_changeset(%{stripe_payment_intent_id: pi_id})
        |> Repo.update()

        {:error, :requires_action, pi_id}

      {:error, reason} ->
        {:error, {:payment_failed, reason}}
    end
  end

  defp finalize_paid_session(session, payment_intent_id) do
    customer_name = session.customer_name || "ACP Agent"

    with {:ok, org} <-
           ApiKeys.find_or_create_org(customer_name, tier: "pro", status: "active"),
         {:ok, raw_key, _api_key} <-
           ApiKeys.create_api_key(org, "acp-key", ["admin", "analyze"]),
         {:ok, recovery_code} <- ApiKeys.generate_recovery_code(org) do
      session
      |> AcpCheckoutSession.update_changeset(%{
        status: "completed",
        stripe_payment_intent_id: payment_intent_id,
        org_id: org.id
      })
      |> Repo.update()

      {:ok,
       %{
         api_key: raw_key,
         recovery_code: recovery_code,
         org_slug: org.slug,
         tier: "pro"
       }}
    end
  end
end
