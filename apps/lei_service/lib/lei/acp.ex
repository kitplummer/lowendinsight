defmodule Lei.Acp do
  @moduledoc """
  ACP (Agentic Commerce Protocol) business logic for agent-to-agent commerce.
  Manages checkout session lifecycle: create → update → complete/cancel.
  """
  alias Lei.{Repo, AcpCheckoutSession, ApiKeys, Credits, Org}

  @session_ttl_seconds 3600

  def create_session(sku) do
    amount = AcpCheckoutSession.amount_for_sku(sku)

    cond do
      # Before anything is written: a switched-off path opens nothing.
      not Lei.Payments.Switches.enabled?("acp") ->
        {:error, :switched_off}

      is_nil(amount) ->
        {:error, :invalid_sku}

      true ->
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
    with :ok <- check_switch(),
         {:ok, session} <- get_session(id),
         :ok <- check_session_open(session),
         :ok <- check_not_expired(session),
         # Before the charge, not after: a name that cannot be created would
         # otherwise take the agent's money for nothing.
         :ok <- check_name_available(session) do
      complete_paid_session(session, payment_params)
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

  # Checked before the card is charged, so a session opened before the switch
  # completes nothing and costs the agent nothing.
  defp check_switch do
    if Lei.Payments.Switches.enabled?("acp"), do: :ok, else: {:error, :switched_off}
  end

  defp check_session_open(%AcpCheckoutSession{status: "open"}), do: :ok
  defp check_session_open(_session), do: {:error, :session_not_open}

  defp check_not_expired(%AcpCheckoutSession{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :session_expired}
    end
  end

  defp check_name_available(session) do
    slug = ApiKeys.slugify(session.customer_name || default_org_name(session))

    case Repo.get_by(Org, slug: slug) do
      nil -> :ok
      _ -> {:error, :name_taken}
    end
  end

  defp complete_paid_session(session, payment_params) do
    stripe = Lei.Stripe.impl()
    payment_method = payment_params["payment_method"] || payment_params["shared_payment_token"]

    case stripe.create_payment_intent(%{
           amount: session.amount_cents,
           currency: session.currency,
           payment_method: payment_method,
           # How Stripe's side knows this is a credit purchase, so reconciliation
           # can find one Stripe received and the ledger never credited
           # (Lei.StripeReconciliation). The MPP rails set challenge_id.
           metadata: %{
             "lei_rail" => "acp",
             "acp_session_id" => session.id,
             "credits" => to_string(AcpCheckoutSession.credits_for_amount(session.amount_cents))
           }
         }) do
      {:ok, %{"id" => pi_id, "status" => "succeeded"}} ->
        finalize_paid_session(session, pi_id)

      {:ok, %{"id" => pi_id, "status" => "requires_action"}} ->
        session
        |> AcpCheckoutSession.update_changeset(%{stripe_payment_intent_id: pi_id})
        |> Repo.update()

        {:error, :requires_action, pi_id}

      # Only the decline code. Stripe's error body can carry the PaymentIntent,
      # its client secret and a request log URL.
      {:error, reason} ->
        {:error, {:payment_failed, decline_code(reason)}}
    end
  end

  # Org, credentials, credits and the session's completion are one fact: an
  # agent that paid either has all of them or none. The credit entry is keyed
  # to the PaymentIntent, so the same payment cannot be credited twice.
  defp finalize_paid_session(session, payment_intent_id) do
    customer_name = session.customer_name || default_org_name(session)
    credits = AcpCheckoutSession.credits_for_amount(session.amount_cents)

    Repo.transaction(fn ->
      with {:ok, org} <- ApiKeys.create_org(customer_name, tier: "free", status: "active"),
           {:ok, org} <-
             org
             |> Ecto.Changeset.change(prepaid: true, free_tier_analyses_limit: 0)
             |> Repo.update(),
           {:ok, _entry} <-
             Credits.grant(org.id, credits, "purchase:stripe",
               external_ref: "acp:" <> payment_intent_id,
               usd_value_cents: session.amount_cents,
               metadata: %{"acp_session_id" => session.id, "sku" => session.sku}
             ),
           {:ok, raw_key, _api_key} <-
             ApiKeys.create_api_key(org, "acp-key", ["admin", "analyze"]),
           {:ok, recovery_code} <- ApiKeys.generate_recovery_code(org),
           {:ok, _session} <-
             session
             |> AcpCheckoutSession.update_changeset(%{
               status: "completed",
               stripe_payment_intent_id: payment_intent_id,
               org_id: org.id
             })
             |> Repo.update() do
        %{
          api_key: raw_key,
          recovery_code: recovery_code,
          org_slug: org.slug,
          tier: "prepaid",
          credits: credits
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp decline_code(%{"error" => %{} = error}),
    do: error["decline_code"] || error["code"] || "payment_failed"

  defp decline_code(_), do: "payment_failed"

  # A fixed default ("ACP Agent") would slug-collide for every anonymous
  # completion, so each one would land on the same org. Under the old
  # find-or-create behaviour that silently issued admin keys for a shared org;
  # under create_org/2 it would fail every caller after the first. Derive the
  # name from the session id so anonymous agents each get their own org.
  defp default_org_name(session) do
    "ACP Agent " <> String.slice(session.id, -12, 12)
  end
end
