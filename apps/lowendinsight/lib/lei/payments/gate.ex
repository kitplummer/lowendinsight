defmodule Lei.Payments.Gate do
  @moduledoc """
  Who may run a paid request, and what to say to those who may not.

  One module because there are two routers. `POST /v1/analyze` is served by
  `LowendinsightGet.Endpoint` and `POST /v1/analyze/batch` by `Lei.Web.Router`,
  and #131 wired payment into only the second -- behind an auth plug that
  rejected the Payment scheme first. Every test passed and no agent could pay
  (#147). Both routes now ask this.

  ## The rule

    * a signed operator token (JWT) is not billed, as before
    * an org -- from an API key, or from a payment on this request -- is
      checked against its tier and balance
    * anything else is asked to pay. Not told to authenticate: an agent that
      has never been here has nothing to authenticate with, and the payment
      is how it becomes someone

  The last case is the default, so a request that reaches here unrecognised is
  challenged rather than served.
  """

  import Plug.Conn

  alias Lei.Payments.Http

  @paid_routes [{"POST", "/v1/analyze"}, {"POST", "/v1/analyze/batch"}]

  @doc """
  Whether a request may arrive with no credentials, to be asked to pay.

  Both auth plugs consult this. Everything else under /v1 still requires
  authentication.
  """
  def paid_route?(%Plug.Conn{method: method, request_path: path}),
    do: {method, path} in @paid_routes

  @doc """
  Honours a payment presented on the request. There is no separate endpoint to
  pay at: the caller retries what it originally asked for, with a credential.
  """
  def settle(conn) do
    case Http.settle(conn) do
      {:ok, conn, settlement} ->
        conn
        |> assign(:payment_org_id, conn.assigns[:settled_org_id])
        |> assign(:payment_settlement, settlement)

      {:rate_limited, conn} ->
        conn

      :no_credential ->
        conn

      # A credential that did not settle leaves the caller where it started:
      # admit/1 asks it to pay.
      {:error, _reason} ->
        conn
    end
  end

  @doc """
  `{:ok, conn, {org_id, api_key_id, tier}}` to proceed, or `{:halt, conn}` with
  the response already sent.
  """
  def admit(%Plug.Conn{halted: true} = conn), do: {:halt, conn}

  def admit(conn) do
    case billing_context(conn) do
      {nil, _, _} = context ->
        if conn.assigns[:auth_method] == :jwt do
          {:ok, conn, context}
        else
          {:halt, Http.challenge(conn, nil, default_top_up())}
        end

      {_org_id, _, "pro"} = context ->
        {:ok, conn, context}

      {org_id, _, _} = context ->
        case Lei.UsageTracker.check_free_tier_quota(org_id) do
          {:ok, _remaining} ->
            {:ok, conn, context}

          {:error, :quota_exceeded, info} ->
            {:halt,
             json(conn, 402, %{
               error: "free_tier_quota_exceeded",
               used: info.used,
               limit: info.limit,
               upgrade_url: "https://lowendinsight.fly.dev/signup?tier=pro"
             })}

          # A 402 carrying real payment requirements, not just a balance.
          {:error, :insufficient_credits, info} ->
            {:halt, Http.challenge(conn, org_id, top_up_credits(info))}

          {:error, _} ->
            {:ok, conn, context}
        end
    end
  end

  @doc "`{org_id, api_key_id, tier}` for the request, from its key or its payment."
  def billing_context(conn) do
    case conn.assigns[:current_api_key] do
      nil ->
        # A wallet-identified agent has no API key on the request that pays --
        # the payment is how it identifies itself.
        case conn.assigns[:payment_org_id] && Lei.Repo.get(Lei.Org, conn.assigns[:payment_org_id]) do
          %Lei.Org{} = org -> {org.id, nil, org.tier}
          _ -> {nil, nil, nil}
        end

      api_key ->
        {api_key.org.id, api_key.id, api_key.org.tier}
    end
  end

  # A block rather than the exact shortfall: settling costs something on every
  # rail, so charging for one analysis at a time would spend more on collection
  # than the analysis is worth. 15,000 credits is $15, matching the Pro tier's
  # monthly credit. A negative balance is added back, or an org in debt would
  # be topped up to less than zero and refused again.
  defp top_up_credits(%{balance: balance}) when is_integer(balance) and balance < 0,
    do: default_top_up() - balance

  defp top_up_credits(_info), do: default_top_up()

  defp default_top_up, do: Application.get_env(:lowendinsight, :default_top_up_credits, 15_000)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(body))
    |> halt()
  end
end
