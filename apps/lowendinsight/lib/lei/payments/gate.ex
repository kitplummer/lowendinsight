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

  @paid_routes [
    {"POST", "/v1/analyze"},
    {"POST", "/v1/analyze/batch"},
    {"POST", "/v1/analyze/sbom"}
  ]

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

  `:required_credits` is what the request will cost, when the caller can say.
  `:analyses` is how many analyses it will run, which is what a free org's
  monthly allowance counts.
  A credit-funded org holding less is asked to top up by at least the
  shortfall, rather than admitted and run into debt: an SBOM naming hundreds of
  uncached repositories costs far more than one block (#152).
  """
  def admit(conn, opts \\ [])

  def admit(%Plug.Conn{halted: true} = conn, _opts), do: {:halt, conn}

  def admit(conn, opts) do
    required = Keyword.get(opts, :required_credits, 0)
    analyses = Keyword.get(opts, :analyses, 0)

    case billing_context(conn) do
      {nil, _, _} = context ->
        if conn.assigns[:auth_method] == :jwt do
          {:ok, conn, context}
        else
          {:halt, Http.challenge(conn, nil, top_up(0, required))}
        end

      {_org_id, _, "pro"} = context ->
        {:ok, conn, context}

      {org_id, _, _} = context ->
        # Two different allowances, in two different units, and the answer
        # from check_free_tier_quota/1 means a different thing for each: a
        # wallet org's credit balance, or a free org's analyses remaining. The
        # gate compared the second against a price in credits and then admitted
        # the request anyway, so the monthly limit never bounded a request --
        # only whether one could start.
        if credit_funded?(org_id),
          do: admit_credit_funded(conn, context, required),
          else: admit_free(conn, context, analyses)
    end
  end

  defp admit_credit_funded(conn, {org_id, _, _} = context, required) do
    case Lei.UsageTracker.check_free_tier_quota(org_id) do
      {:ok, balance} when is_integer(balance) and balance < required ->
        {:halt, Http.challenge(conn, org_id, top_up(balance, required))}

      {:ok, _balance} ->
        {:ok, conn, context}

      # A 402 carrying real payment requirements, not just a balance.
      {:error, :insufficient_credits, %{balance: balance}} ->
        {:halt, Http.challenge(conn, org_id, top_up(balance, required))}

      {:error, _} ->
        {:halt, Http.challenge(conn, org_id, top_up(0, required))}
    end
  end

  defp admit_free(conn, {org_id, _, _} = context, analyses) do
    case Lei.UsageTracker.check_free_tier_quota(org_id) do
      {:ok, remaining} when is_integer(remaining) and analyses > remaining ->
        limit_reached(conn, %{requested: analyses, remaining: remaining})

      {:ok, _remaining} ->
        {:ok, conn, context}

      {:error, :quota_exceeded, info} ->
        limit_reached(conn, %{
          used: info.used,
          limit: info.limit,
          requested: analyses,
          remaining: 0
        })

      {:error, _} ->
        {:ok, conn, context}
    end
  end

  defp limit_reached(conn, detail) do
    {:halt,
     json(
       conn,
       402,
       Map.merge(
         %{
           error: "free_tier_quota_exceeded",
           upgrade_url: "https://lowendinsight.fly.dev/signup?tier=pro"
         },
         detail
       )
     )}
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
  # be topped up to less than zero and refused again. And never less than the
  # request needs, or the agent pays and is refused again.
  defp top_up(balance, required) do
    max(default_top_up() - min(balance, 0), required - balance)
  end

  defp credit_funded?(org_id) do
    case Lei.Repo.get(Lei.Org, org_id) do
      %Lei.Org{prepaid: true} -> true
      org -> Lei.Wallets.wallet_org?(org)
    end
  end

  defp default_top_up, do: Application.get_env(:lowendinsight, :default_top_up_credits, 15_000)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(body))
    |> halt()
  end
end
