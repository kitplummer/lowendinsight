defmodule Lei.Payments.Http do
  @moduledoc """
  The HTTP side of paying: issuing a 402 challenge and honouring a credential.

  MPP is an HTTP authentication scheme, so this is not a bespoke endpoint pair.
  A caller asks for the resource it wants; if it cannot pay yet it gets a 402
  carrying `WWW-Authenticate: Payment`, and it retries the *same* request with
  `Authorization: Payment`. One URL serves paying and non-paying callers, which
  is the property that makes it usable by an agent that has never been here
  before.

  ## Challenges are remembered, not trusted

  The credential echoes the challenge, and the echo is only worth checking
  against a challenge we actually issued -- comparing it against its own copy
  would be circular. So issued challenges are held briefly in the cache, keyed
  by id.

  Postgres rather than process state, because the app runs more than one node
  and a challenge issued by one is answered against another. A challenge we
  cannot find is refused rather than trusted -- the alternative is accepting a
  credential's own account of what it is answering.
  """

  import Plug.Conn

  require Logger

  alias Lei.Payments
  alias Lei.Payments.ChallengeStore
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}

  @doc """
  Answers an unfunded request with a payment challenge.
  """
  def challenge(conn, org_id, credits, opts \\ []) do
    conn = Lei.Payments.RateLimit.check(conn, :payment_challenge)

    if Lei.Payments.RateLimit.limited?(conn) do
      conn
    else
      issue(conn, org_id, credits, opts)
    end
  end

  defp issue(conn, org_id, credits, opts) do
    rail = Keyword.get(opts, :rail, default_rail())

    case rail.requirements(credits, opts) do
      {:ok, challenge} ->
        with :ok <- remember(challenge, org_id, rail) do
          conn
          |> put_resp_header("www-authenticate", Challenge.to_header(challenge))
          |> put_resp_content_type("application/json")
          |> send_resp(
            402,
            Poison.encode!(%{
              error: "payment required",
              credits: credits,
              # Restated in the body because an agent that does not speak the
              # auth scheme can still read this and decide what to do, and a
              # human reading a log can see the price without base64-decoding a
              # header.
              amount: challenge.request["amount"],
              currency: challenge.request["currency"],
              challenge_id: challenge.id
            })
          )
        else
          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(503, Poison.encode!(%{error: "payment temporarily unavailable"}))
        end

      {:error, :no_stripe_profile} ->
        # The caller still needs credits; it just cannot buy them this way. A
        # 500 would say the service is broken when it is declining a sale.
        Logger.error("Payment challenge not issued: STRIPE_PROFILE_ID is not configured")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          402,
          Poison.encode!(%{
            error: "insufficient credits",
            credits: credits,
            payment: "unavailable"
          })
        )

      {:error, reason} ->
        Logger.error("Could not build payment requirements: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Poison.encode!(%{error: "payment unavailable"}))
    end
  end

  @doc """
  Verifies a credential on the request and credits the org.

  Returns `{:ok, conn, settlement}` with the receipt already on the connection,
  `{:error, reason}` for anything that did not settle, or `:no_credential` when
  the caller simply has not paid yet -- which is not an error, it is the first
  half of the exchange.
  """
  def settle(conn, opts \\ []) do
    conn = Lei.Payments.RateLimit.check(conn, :payment_settle)

    if Lei.Payments.RateLimit.limited?(conn) do
      {:rate_limited, conn}
    else
      do_settle(conn, opts)
    end
  end

  defp do_settle(conn, opts) do
    with {:ok, header} <- credential_header(conn),
         {:ok, credential} <- Credential.from_header(header),
         {:ok, issued, record, rail} <- recall(credential),
         {:ok, settlement} <- rail.verify(credential, Keyword.put(opts, :challenge, issued)),
         {:ok, _entry} <- credit(record.org_id, settlement) do
      ChallengeStore.mark_settled(record)

      receipt = Receipt.new(method: rail.name(), reference: settlement.settlement_ref)

      conn =
        conn
        |> put_resp_header("payment-receipt", Receipt.to_header(receipt))
        # Who paid, taken from the recorded challenge. The caller needs it to
        # bill the right org, and it is not derivable from the request.
        |> Plug.Conn.assign(:settled_org_id, record.org_id)

      {:ok, conn, settlement}
    end
  end

  # A settlement that was already credited is not a failure. The agent paid
  # once, retried, and is entitled to the resource either way -- refusing the
  # retry would take the money and withhold the work.
  defp credit(org_id, settlement) do
    case Payments.credit_settlement(org_id, settlement) do
      {:ok, entry} -> {:ok, entry}
      {:error, :duplicate} -> {:ok, :already_credited}
      other -> other
    end
  end

  defp credential_header(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] -> {:ok, value}
      [] -> :no_credential
    end
  end

  # Recorded with the org it was issued to. A credential proves a payment
  # happened; it does not prove who it was for, and crediting whoever presents
  # one would let an agent top up another's balance.
  defp remember(%Challenge{} = challenge, org_id, rail) do
    case ChallengeStore.put(challenge, org_id, rail) do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        # Without a recorded challenge the credential cannot be checked, so a
        # failure here has to stop the exchange rather than issue a challenge
        # that can never be answered.
        Logger.error("Could not record payment challenge #{challenge.id}: #{inspect(reason)}")
        {:error, :challenge_not_recorded}
    end
  end

  defp recall(%Credential{challenge: echoed}) do
    with {:ok, challenge, record} <- ChallengeStore.fetch(echoed["id"]),
         {:ok, rail} <- rail_named(record.rail) do
      {:ok, challenge, record, rail}
    end
  end

  defp rail_named(name) do
    case Enum.find(configured_rails(), &(&1.name() == name)) do
      nil -> {:error, {:unknown_rail, name}}
      rail -> {:ok, rail}
    end
  end

  defp default_rail do
    case configured_rails() do
      [rail | _] -> rail
      [] -> Lei.Payments.Rails.Mpp
    end
  end

  defp configured_rails do
    Application.get_env(:lowendinsight, :payment_rails, [Lei.Payments.Rails.Mpp])
  end
end
