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

  alias Lei.{ApiKeys, Org, Payments, Repo, Wallets}
  alias Lei.Payments.{ChallengeStore, MachineRail, Outcomes, Switches}
  alias Lei.Payments.Mpp.{Challenge, Credential, Receipt}

  @doc """
  Answers an unfunded request with a payment challenge.

  `org_id` is nil for a caller with no org -- an agent that has never been
  here. Only rails that can identify their payer are offered then, because the
  org it ends up with is the payer's (#147).
  """
  def challenge(conn, org_id, credits, opts \\ []) do
    conn = Lei.Payments.RateLimit.check(conn, :payment_challenge)

    if Lei.Payments.RateLimit.limited?(conn) do
      Outcomes.record("unknown", "rate_limited", :payment_challenge)
      conn
    else
      issue(conn, org_id, credits, opts)
    end
  end

  defp issue(conn, org_id, credits, opts) do
    rails =
      opts
      |> Keyword.get_lazy(:rails, &configured_rails/0)
      |> Enum.filter(&(org_id != nil or MachineRail.identifies_payer?(&1)))

    # A switched-off rail is not asked for requirements at all: it is
    # unavailable, for a reason the 402 and the counts can both name.
    results =
      Enum.map(rails, fn rail ->
        if Switches.enabled?(rail.name()),
          do: {rail, rail.requirements(credits, opts)},
          else: {rail, {:error, {:unavailable, :switched_off}}}
      end)

    offered = for {rail, {:ok, challenge}} <- results, do: {rail, challenge}

    unavailable =
      for {rail, {:error, {:unavailable, reason}}} <- results, do: {rail.name(), reason}

    failed =
      for {rail, {:error, reason}} <- results,
          not match?({:unavailable, _}, reason),
          do: {rail.name(), reason}

    for {name, reason} <- unavailable do
      Logger.info("Payment rail #{name} offered no challenge: #{inspect(reason)}")
      Outcomes.record(name, "unavailable", reason)
    end

    for {name, reason} <- failed do
      Logger.error("Could not build #{name} payment requirements: #{inspect(reason)}")
      Outcomes.record(name, "challenge_error", reason)
    end

    cond do
      offered != [] ->
        send_challenges(conn, org_id, credits, offered)

      failed == [] ->
        # Every rail is unavailable -- not configured, or not yet confirmed.
        # The caller still needs credits; it just cannot buy them this way. A
        # 500 would say the service is broken when it is declining a sale, and
        # a challenge would look payable and fail at the wallet (#143).
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

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Poison.encode!(%{error: "payment unavailable"}))
    end
  end

  # One WWW-Authenticate value per method, which is how the scheme offers a
  # choice: an agent with a card-backed wallet answers the stripe challenge, one
  # holding stablecoin answers tempo. Each is recorded, because either may be
  # the one answered.
  defp send_challenges(conn, org_id, credits, offered) do
    recorded = Enum.map(offered, fn {rail, challenge} -> remember(challenge, org_id, rail) end)

    if Enum.all?(recorded, &(&1 == :ok)) do
      for {rail, _challenge} <- offered, do: Outcomes.record(rail.name(), "issued")
      [{_rail, first} | _] = offered

      conn
      |> prepend_resp_headers(
        Enum.map(offered, fn {_rail, challenge} ->
          {"www-authenticate", Challenge.to_header(challenge)}
        end)
      )
      |> put_resp_content_type("application/json")
      |> send_resp(
        402,
        Poison.encode!(%{
          error: "payment required",
          credits: credits,
          # Restated in the body because an agent that does not speak the
          # auth scheme can still read this and decide what to do, and a
          # human reading a log can see the price without base64-decoding a
          # header. Top-level fields describe the first challenge, as before.
          amount: first.request["amount"],
          currency: first.request["currency"],
          challenge_id: first.id,
          challenges:
            Enum.map(offered, fn {_rail, challenge} ->
              %{
                method: challenge.method,
                challenge_id: challenge.id,
                amount: challenge.request["amount"],
                currency: challenge.request["currency"]
              }
            end)
        })
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Poison.encode!(%{error: "payment temporarily unavailable"}))
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
    # Only a request presenting a Payment credential spends from the settle
    # bucket. Checked the other way round, every paid request counted -- ten a
    # minute per IP for all analysis, keyed or not, once both analyze routes
    # passed through here (#147).
    cond do
      not payment_credential?(conn) ->
        :no_credential

      # An operator crediting a held payment (Lei.Payments.Held), not a caller.
      Keyword.get(opts, :release_held, false) ->
        do_settle(conn, opts)

      true ->
        rate_limited_settle(conn, opts)
    end
  end

  defp rate_limited_settle(conn, opts) do
    conn = Lei.Payments.RateLimit.check(conn, :payment_settle)

    if Lei.Payments.RateLimit.limited?(conn) do
      Outcomes.record("unknown", "rate_limited", :payment_settle)
      {:rate_limited, conn}
    else
      do_settle(conn, opts)
    end
  end

  defp payment_credential?(conn) do
    case get_req_header(conn, "authorization") do
      ["Payment " <> _ | _] -> true
      _ -> false
    end
  end

  # Counted in two halves so the rail is known for every refusal it can be:
  # a credential that cannot be parsed, or names a challenge we never issued,
  # has no rail, and is counted as "unknown".
  defp do_settle(conn, opts) do
    with {:ok, header} <- credential_header(conn),
         {:ok, credential} <- Credential.from_header(header),
         {:ok, issued, record, rail} <- recall(credential) do
      # Before the attempt: presented minus settled and refused is attempts
      # that raised part-way.
      Outcomes.record(rail.name(), "presented")

      conn
      |> settle_recalled(header, credential, issued, record, rail, opts)
      |> tap(&count_settlement(&1, rail, record))
    else
      {:error, reason} = error ->
        Outcomes.record("unknown", "presented")
        Outcomes.record("unknown", "refused", reason)
        error

      other ->
        other
    end
  end

  defp count_settlement({:ok, _conn, _settlement}, rail, record) do
    # A settled challenge presented again is the retry of an agent whose
    # response was lost. Counting it as another settlement would inflate
    # conversion, which is settled challenges over issued ones.
    Outcomes.record(rail.name(), "settled", if(record.settled_at, do: "retry"))
  end

  defp count_settlement({:error, reason}, rail, _record),
    do: Outcomes.record(rail.name(), "refused", reason)

  defp count_settlement(_other, _rail, _record), do: :ok

  # Switched off: nothing is verified and nothing is credited. Where the payer
  # has already paid, the credential is held rather than dropped.
  defp settle_recalled(conn, header, credential, issued, record, rail, opts) do
    releasing? = Keyword.get(opts, :release_held, false)

    if not releasing? and not Switches.enabled?(rail.name()) do
      if MachineRail.funds_move_before_settlement?(rail) do
        case ChallengeStore.hold(record, header) do
          {:ok, _} ->
            Logger.warning(
              "#{rail.name()} credential for #{record.challenge_id} held: rail switched off"
            )

          {:error, reason} ->
            Logger.error(
              "Could not hold #{rail.name()} credential for #{record.challenge_id}: #{inspect(reason)}"
            )
        end
      end

      {:error, :rail_disabled}
    else
      # A held payment is released after its challenge has expired, which is
      # the operator's decision to make, not a stale credential.
      issued = if releasing?, do: %{issued | expires: nil}, else: issued
      verify_and_credit(conn, credential, issued, record, rail, opts)
    end
  end

  defp verify_and_credit(conn, credential, issued, record, rail, opts) do
    with {:ok, settlement} <- rail.verify(credential, Keyword.put(opts, :challenge, issued)),
         {:ok, org_id, issued_key} <- credit_payer(record, rail, settlement) do
      ChallengeStore.mark_settled(record, org_id)

      receipt = Receipt.new(method: rail.name(), reference: settlement.settlement_ref)

      conn =
        conn
        |> put_resp_header("payment-receipt", Receipt.to_header(receipt))
        |> maybe_put_key(issued_key)
        # Who paid, taken from the recorded challenge -- or, for a caller that
        # had no org, from the payment itself. The caller needs it to bill the
        # right org, and it is not derivable from the request.
        |> Plug.Conn.assign(:settled_org_id, org_id)

      {:ok, conn, settlement}
    end
  end

  # The key an agent comes back with. Without it, the 15,000 credits it just
  # bought are stranded: its next request carries no credential and is asked
  # to pay again (#147).
  defp maybe_put_key(conn, nil), do: conn
  defp maybe_put_key(conn, raw_key), do: put_resp_header(conn, "lei-api-key", raw_key)

  # A challenge issued to an org credits that org, whoever presents the proof.
  defp credit_payer(%{org_id: org_id}, _rail, settlement) when not is_nil(org_id) do
    case credit(org_id, settlement) do
      {:ok, _} -> {:ok, org_id, nil}
      error -> error
    end
  end

  # A challenge issued to no one credits the wallet that paid, and hands back a
  # key for it.
  #
  # This is an unauthenticated path that issues a credential -- the shape #89
  # was an org takeover through. What makes it safe is where the identity comes
  # from: a transfer the rail verified on chain, bound to this challenge by its
  # memo, signed by the holder, and confirmed by Stripe. Nothing the caller
  # asserts is consulted. Anyone who can make that payment controls the wallet.
  defp credit_payer(%{org_id: nil}, rail, settlement) do
    with {:ok, wallet} <- payer_wallet(rail, settlement),
         {:ok, org} <- wallet_org(wallet) do
      # The credit and the key describe one event, so they commit together. A
      # credit without its key strands the balance, and a replay could not
      # recover it: the duplicate is refused before a key would be issued.
      Repo.transaction(fn ->
        case Payments.credit_settlement(org.id, settlement) do
          {:ok, _entry} ->
            case ApiKeys.create_api_key(org, "mpp #{rail.name()}", ["analyze"]) do
              {:ok, raw_key, _api_key} -> {org.id, raw_key}
              {:error, reason} -> Repo.rollback({:key_not_issued, reason})
            end

          # Postgres has aborted the transaction on the unique violation, so
          # nothing more can run in it. A replay: credited before, keyed before.
          {:error, :duplicate} ->
            Repo.rollback(:duplicate)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {org_id, raw_key}} -> {:ok, org_id, raw_key}
        {:error, :duplicate} -> {:ok, org.id, nil}
        {:error, reason} -> {:error, {:credit_failed, reason}}
      end
    end
  end

  defp payer_wallet(rail, settlement) do
    wallet = if MachineRail.identifies_payer?(rail), do: rail.payer_wallet(settlement)

    case wallet do
      nil ->
        Logger.error("#{rail.name()} settled an anonymous challenge without identifying a payer")
        {:error, :payer_unidentified}

      wallet ->
        {:ok, wallet}
    end
  end

  # Create-only, with the unique index as arbiter: two agents paying from one
  # wallet at once both reach provision/2, one wins, the other finds it. Done
  # outside the credit transaction, because a unique violation inside one aborts
  # it.
  defp wallet_org(wallet) do
    case Wallets.find_by_address(wallet) do
      %Org{} = org ->
        {:ok, org}

      nil ->
        case Wallets.provision(wallet) do
          {:ok, org} ->
            {:ok, org}

          {:error, :wallet_taken} ->
            case Wallets.find_by_address(wallet) do
              %Org{} = org -> {:ok, org}
              nil -> {:error, :wallet_org_unavailable}
            end

          {:error, reason} ->
            {:error, {:wallet_org_unavailable, reason}}
        end
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

  defp configured_rails do
    Application.get_env(:lei_service, :payment_rails, [Lei.Payments.Rails.Mpp])
  end
end
