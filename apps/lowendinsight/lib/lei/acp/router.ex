defmodule Lei.Acp.Router do
  @moduledoc """
  ACP (Agentic Commerce Protocol) router.
  4 endpoints for agent-to-agent checkout session lifecycle.
  """
  use Plug.Router

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Poison,
    body_reader: {Lei.Acp.RawBodyReader, :read_body, []}
  )

  plug(Lei.Acp.Auth)
  plug(:match)
  plug(:dispatch)

  # POST /acp/checkout — Create a new checkout session
  post "/checkout" do
    sku = conn.body_params["sku"]

    case Lei.Acp.create_session(sku) do
      {:ok, session} ->
        json_resp(conn, 201, %{
          id: session.id,
          sku: session.sku,
          amount_cents: session.amount_cents,
          currency: session.currency,
          status: session.status,
          expires_at: DateTime.to_iso8601(session.expires_at)
        })

      {:error, :invalid_sku} ->
        json_resp(conn, 400, %{
          error: "invalid SKU",
          valid_skus: Lei.AcpCheckoutSession.valid_skus()
        })
    end
  end

  # POST /acp/checkout/:id — Update session (customer details)
  post "/checkout/:id" do
    attrs = %{
      customer_name: conn.body_params["customer_name"],
      metadata: conn.body_params["metadata"]
    }

    case Lei.Acp.update_session(id, attrs) do
      {:ok, session} ->
        json_resp(conn, 200, %{
          id: session.id,
          status: session.status,
          customer_name: session.customer_name
        })

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "session not found"})

      {:error, :session_not_open} ->
        json_resp(conn, 409, %{error: "session is no longer open"})
    end
  end

  # POST /acp/checkout/:id/complete — Complete session (process payment + create org)
  post "/checkout/:id/complete" do
    case Lei.Acp.complete_session(id, conn.body_params) do
      {:ok, result} ->
        json_resp(conn, 200, %{
          api_key: result.api_key,
          recovery_code: result.recovery_code,
          org_slug: result.org_slug,
          tier: result.tier,
          warning: "Store these credentials securely. They will not be shown again."
        })

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "session not found"})

      {:error, :session_not_open} ->
        json_resp(conn, 409, %{error: "session is no longer open"})

      {:error, :session_expired} ->
        json_resp(conn, 410, %{error: "session has expired"})

      {:error, :requires_action, payment_intent_id} ->
        json_resp(conn, 402, %{
          error: "payment requires additional action",
          payment_intent_id: payment_intent_id
        })

      {:error, {:payment_failed, reason}} ->
        json_resp(conn, 402, %{error: "payment failed", details: inspect(reason)})
    end
  end

  # POST /acp/checkout/:id/cancel — Cancel session
  post "/checkout/:id/cancel" do
    case Lei.Acp.cancel_session(id) do
      {:ok, session} ->
        json_resp(conn, 200, %{id: session.id, status: session.status})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "session not found"})

      {:error, :session_not_open} ->
        json_resp(conn, 409, %{error: "session is no longer open"})
    end
  end

  match _ do
    json_resp(conn, 404, %{error: "not found"})
  end

  defp json_resp(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(data))
  end
end
