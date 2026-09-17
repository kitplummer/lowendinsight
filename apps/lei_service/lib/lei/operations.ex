defmodule Lei.Operations do
  @moduledoc """
  What a payment runbook does, as functions an agent can call (#139).

  An operator -- a person or an agent -- runs these through
  `scripts/payments.sh`, which reaches this module over `rpc`. So every
  operation:

    * takes its arguments as data -- `cli/2` receives base64 JSON, and nothing
      passed in is ever evaluated;
    * answers with a map carrying `ok`, encoded as JSON, so the script can set
      its exit code and the agent can read the result without parsing prose;
    * is safe to repeat: switching to the state a path is already in changes
      nothing, and a refund is keyed so a retry reaches the same refund.

  Which of these an agent may run without asking is not decided here: in a
  Claude Code session, `.claude/settings.json` makes the ones that move money
  prompt first.
  """

  import Ecto.Query
  require Logger

  alias Lei.{CreditEntry, Credits, Repo, StripeReconciliation}
  alias Lei.Payments.{Held, Outcomes, Switches}

  @commands ~w(status switch held release ledger refund reconciliation)
  @purchase_prefixes ~w(acp mpp tempo)

  @doc """
  The entry point `scripts/payments.sh` calls. Returns a JSON string.
  """
  def cli(command, encoded_args) when is_binary(command) and is_binary(encoded_args) do
    with {:ok, json} <- Base.decode64(encoded_args),
         {:ok, %{} = args} <- Poison.decode(json) do
      if command in @commands do
        run(command, args)
      else
        failure(:unknown_command)
      end
    else
      _ -> failure(:invalid_arguments)
    end
    |> Poison.encode!()
  rescue
    error ->
      Logger.error("Lei.Operations #{command} raised: #{Exception.message(error)}")
      Poison.encode!(failure(:raised, Exception.message(error)))
  end

  defp run("status", _args), do: status()

  defp run("switch", args),
    do: switch(args["path"], args["enabled"], args["reason"], args["actor"])

  defp run("held", _args), do: held()
  defp run("release", args), do: release(args["challenge_id"])
  defp run("ledger", args), do: ledger(args["payment_intent"])
  defp run("reconciliation", _args), do: reconciliation()

  defp run("refund", args),
    do: refund(args["payment_intent"], args["amount_cents"], args["reason"], args["actor"])

  # -- reading

  @doc "Every switch, held payments by rail, the last 24 hours of outcomes, the latest reconciliation."
  def status do
    %{
      ok: true,
      switches: Map.new(Switches.state(), fn {path, s} -> {path, timestamps(s)} end),
      held: Held.counts(),
      outcomes_24h: Outcomes.summary(),
      reconciliation: StripeReconciliation.latest() |> run_summary()
    }
  end

  @doc "Held payments awaiting a decision."
  def held, do: %{ok: true, held: Enum.map(Held.list(), &timestamps/1)}

  @doc "The latest reconciliation run, with its discrepancies."
  def reconciliation do
    %{ok: true, run: StripeReconciliation.latest() |> run_summary(true)}
  end

  @doc """
  Everything the ledger holds for one PaymentIntent: the purchase, and every
  reversal or reinstatement of it, with the org's balance.
  """
  def ledger(payment_intent) when is_binary(payment_intent) do
    case purchase(payment_intent) do
      nil ->
        failure(:not_a_credit_purchase)

      purchase ->
        related =
          Repo.all(
            from(e in CreditEntry,
              where:
                e.org_id == ^purchase.org_id and
                  (e.id == ^purchase.id or
                     fragment("?->>'reverses'", e.metadata) == ^payment_intent),
              order_by: [asc: e.id]
            )
          )

        %{
          ok: true,
          payment_intent: payment_intent,
          org_id: purchase.org_id,
          balance: Credits.balance(purchase.org_id),
          entries:
            Enum.map(related, fn e ->
              %{
                reason: e.reason,
                delta: e.delta,
                external_ref: e.external_ref,
                usd_value_cents: e.usd_value_cents,
                inserted_at: NaiveDateTime.to_iso8601(e.inserted_at) <> "Z",
                metadata: e.metadata
              }
            end)
        }
    end
  end

  def ledger(_), do: failure(:payment_intent_required)

  # -- acting

  @doc """
  Switches a payment path on or off. Switching to the state it is already in
  records nothing and reports `changed: false`.
  """
  def switch(path, enabled, reason, actor) do
    cond do
      path not in Switches.paths() ->
        failure(:unknown_path)

      not is_boolean(enabled) ->
        failure(:enabled_must_be_boolean)

      not present?(reason) ->
        failure(:reason_required)

      Switches.enabled?(path) == enabled ->
        %{ok: true, path: path, enabled: enabled, changed: false}

      true ->
        case Switches.set(path, enabled, reason, actor || "operations") do
          {:ok, change} -> %{ok: true, path: path, enabled: change.enabled, changed: true}
          {:error, reason} -> failure(reason)
        end
    end
  end

  @doc "Credits a held payment (`Lei.Payments.Held.release/1`)."
  def release(challenge_id) when is_binary(challenge_id) do
    case Held.release(challenge_id) do
      {:ok, settlement} ->
        %{
          ok: true,
          challenge_id: challenge_id,
          rail: settlement.rail,
          credits: settlement.credits,
          payment_intent: settlement.settlement_ref
        }

      {:error, reason} ->
        failure(reason)
    end
  end

  def release(_), do: failure(:challenge_id_required)

  @doc """
  Refunds a credit purchase through Stripe. `amount_cents` nil refunds the
  rest. Only a PaymentIntent the ledger holds as a credit purchase can be
  refunded here.

  Keyed on the PaymentIntent, the amount and the reason: an agent retrying
  after a timeout reaches the same refund. A second, deliberate partial refund
  of the same amount needs a different reason.

  The credits come back out when Stripe's `charge.refunded` webhook arrives
  (`Lei.Payments.Reversals`), not here: the ledger follows the money. Check with
  `ledger/1`.
  """
  def refund(payment_intent, amount_cents, reason, actor) do
    purchase = if is_binary(payment_intent), do: purchase(payment_intent)

    cond do
      is_nil(purchase) ->
        failure(:not_a_credit_purchase)

      not present?(reason) ->
        failure(:reason_required)

      not (is_nil(amount_cents) or (is_integer(amount_cents) and amount_cents > 0)) ->
        failure(:amount_must_be_positive_cents)

      is_integer(amount_cents) and amount_cents > (purchase.usd_value_cents || 0) ->
        failure(:amount_exceeds_purchase)

      true ->
        stripe_refund(payment_intent, amount_cents, reason, actor)
    end
  end

  defp stripe_refund(payment_intent, amount_cents, reason, actor) do
    key =
      :crypto.hash(:sha256, "#{payment_intent}|#{amount_cents || "full"}|#{reason}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 32)

    params = %{
      payment_intent: payment_intent,
      amount: amount_cents,
      idempotency_key: "lei_refund_" <> key,
      metadata: %{"reason" => reason, "actor" => actor || "operations"}
    }

    case Lei.Stripe.impl().create_refund(params) do
      {:ok, refund} ->
        %{
          ok: true,
          payment_intent: payment_intent,
          refund: refund["id"],
          status: refund["status"],
          amount_cents: refund["amount"]
        }

      {:error, detail} ->
        failure(:stripe_refused, inspect(detail))
    end
  end

  # -- helpers

  defp purchase(payment_intent) do
    refs = Enum.map(@purchase_prefixes, &"#{&1}:#{payment_intent}")

    Repo.one(
      from(e in CreditEntry, where: e.external_ref in ^refs and like(e.reason, "purchase:%"))
    )
  end

  defp run_summary(run, with_discrepancies \\ false)
  defp run_summary(nil, _), do: nil

  defp run_summary(run, with_discrepancies) do
    base = %{
      status: run.status,
      at: NaiveDateTime.to_iso8601(run.inserted_at) <> "Z",
      ledger_purchases: run.ledger_purchases,
      stripe_purchases: run.stripe_purchases,
      discrepancy_count: run.discrepancy_count,
      error: run.error
    }

    if with_discrepancies, do: Map.put(base, :discrepancies, run.discrepancies), else: base
  end

  defp timestamps(map) do
    Map.new(map, fn
      {k, %NaiveDateTime{} = v} -> {k, NaiveDateTime.to_iso8601(v) <> "Z"}
      {k, %DateTime{} = v} -> {k, DateTime.to_iso8601(v)}
      other -> other
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp failure(reason, detail \\ nil) do
    base = %{ok: false, error: to_string(reason)}
    if detail, do: Map.put(base, :detail, detail), else: base
  end
end
