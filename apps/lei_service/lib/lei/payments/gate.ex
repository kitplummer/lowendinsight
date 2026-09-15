defmodule Lei.Payments.Gate do
  require Logger

  @moduledoc """
  Who may run a paid request, and what to say to those who may not.

  One module because there are two routers. `POST /v1/analyze` is served by
  `LeiService.Endpoint` and `POST /v1/analyze/batch` by `Lei.Web.Router`,
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

  `:required_credits` is what the request will cost, and `:usage` the
  `{cache_hits, cache_misses}` it will consume. For an org, admission records
  that usage and debits it: a request that is admitted has been charged.
  A credit-funded org holding less is asked to top up by at least the
  shortfall, rather than admitted and run into debt: an SBOM naming hundreds of
  uncached repositories costs far more than one block (#152).
  """
  def admit(conn, opts \\ [])

  def admit(%Plug.Conn{halted: true} = conn, _opts), do: {:halt, conn}

  def admit(conn, opts) do
    required = Keyword.get(opts, :required_credits, 0)
    {hits, misses} = Keyword.get(opts, :usage, {0, 0})

    case billing_context(conn) do
      {nil, _, _} = context ->
        if conn.assigns[:auth_method] == :jwt do
          {:ok, conn, context}
        else
          {:halt, Http.challenge(conn, nil, top_up(0, required))}
        end

      # Checked and charged in one step, under a lock on the org. Checking here
      # and debiting after the analysis let simultaneous requests all pass a
      # check that one of them could afford (security review, 2026-09-14).
      {org_id, api_key_id, _tier} = context ->
        case Lei.UsageTracker.admit_usage(org_id, api_key_id, hits, misses, required) do
          {:ok, _usage} ->
            {:ok, conn, context}

          {:error, {:insufficient_credits, balance}} ->
            {:halt, Http.challenge(conn, org_id, top_up(balance, required))}

          {:error, {:quota_exceeded, info}} ->
            limit_reached(conn, info)

          # The ledger could not be written. Refused, not served unbilled.
          {:error, reason} ->
            Logger.error("admission failed for org #{org_id}: #{inspect(reason)}")
            {:halt, json(conn, 503, %{error: "billing_unavailable"})}
        end
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

  defp default_top_up, do: Application.get_env(:lei_service, :default_top_up_credits, 15_000)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(body))
    |> halt()
  end
end
