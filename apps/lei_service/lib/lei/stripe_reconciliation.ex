defmodule Lei.StripeReconciliation do
  @moduledoc """
  Compares the ledger's purchases with the payments Stripe received, both ways
  (#139, stage F).

  `Lei.Reconciliation` checks the ledger against recorded usage. Nothing
  checked it against the money. These are the failures only this catches:

    * **credited, never received** -- a ledger purchase whose PaymentIntent
      Stripe does not have, has not succeeded, received less for, or holds in
      the other mode. Credits given away.
    * **received, never credited** -- a succeeded credit purchase at Stripe
      with no ledger entry. A customer paid and got nothing.
    * **refunded, never reversed** -- Stripe refunded more of a purchase than
      the ledger has taken back (#208 should make this impossible; this is how
      we would know it was not).

  ## Per PaymentIntent, not against the balance

  Stripe's balance moves with fees, payouts, Pro subscriptions and disputes,
  and a total that agrees can hide two errors that cancel. Every ledger
  purchase is keyed to one PaymentIntent (`acp:`, `mpp:` or `tempo:` plus the
  id), so each is checked on its own.

  A Stripe PaymentIntent is a credit purchase when its metadata says so:
  `challenge_id` (MPP card and stablecoin) or `lei_rail` (agent card
  checkout). Anything else -- a Pro subscription payment -- is not the
  ledger's.

  ## Window and grace

  Each run looks back `window_days` (7). A PaymentIntent that succeeded less
  than `grace_minutes` (15) ago is not yet expected in the ledger: a
  stablecoin payment succeeds at Stripe a moment before its credit is written.

  ## Verification probes

  Going live means making real payments against production to prove a rail
  works. Stripe received that money and the ledger deliberately never credited
  it, so each probe reports as `received_not_recorded` on every subsequent run
  and never stops. A check that is permanently red is one nobody reads by the
  second week, so probes are excluded by naming convention -- a
  `challenge_id` beginning with `reconciliation_probe_prefix` -- and
  **counted** as `probe_excluded` rather than dropped.

  Two things keep the exclusion from becoming a blind spot. It applies only to
  the "Stripe has it, the ledger does not" branch, so a probe that *did* reach
  the ledger is still checked for amount, mode, currency and refunds like any
  other purchase. And the count is on `/metrics`, so an exclusion that starts
  swallowing more than it should is visible as a number that climbs.

  An empty prefix excludes nothing.

  ## When it cannot do its job

  A Stripe error, a missing key, or more PaymentIntents than `max_pages` pages
  is a **failed** run with the reason, never a clean one with fewer things
  checked. Every run is recorded, and `/metrics` reports the latest with its
  age, so a run that stops happening is visible too.
  """

  import Ecto.Query
  require Logger

  alias Lei.{CreditEntry, Repo}

  @window_days 7
  @grace_minutes 15
  @max_pages 20
  @kept_discrepancies 100
  @purchase_prefixes ~w(acp mpp tempo)
  @probe_prefix "probe"

  defmodule Run do
    @moduledoc false
    use Ecto.Schema

    schema "stripe_reconciliation_runs" do
      field(:window_start, :utc_datetime)
      field(:status, :string)
      field(:ledger_purchases, :integer)
      field(:stripe_purchases, :integer)
      field(:discrepancy_count, :integer)
      field(:discrepancies, {:array, :map}, default: [])
      field(:probe_excluded, :integer, default: 0)
      field(:error, :string)

      timestamps(updated_at: false)
    end
  end

  @doc """
  Runs one comparison and records it. Always `{:ok, %Run{}}`: a run that could
  not compare is recorded with status `"failed"` and why.
  """
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    window_start =
      DateTime.add(now, -Keyword.get(opts, :window_days, @window_days) * 86_400, :second)

    result =
      if configured?() do
        compare(now, window_start, opts)
      else
        {:error, "stripe not configured"}
      end

    record(window_start, result)
  end

  @doc "The most recent run, or nil."
  def latest do
    Repo.one(from(r in Run, order_by: [desc: r.id], limit: 1))
  end

  @doc "How many runs have been recorded."
  def count, do: Repo.aggregate(Run, :count, :id)

  # -- comparing

  defp compare(now, window_start, opts) do
    with {:ok, intents} <- list_intents(DateTime.to_unix(window_start), opts) do
      by_id = Map.new(intents, &{&1["id"], &1})
      purchases = ledger_purchases(window_start)
      refunded = refunded_cents(purchases)

      {ledger_side, fetched} =
        Enum.map_reduce(purchases, %{}, fn purchase, fetched ->
          case Map.fetch(by_id, purchase.pi) do
            {:ok, intent} ->
              {check_purchase(purchase, {:ok, intent}, refunded), fetched}

            # Created before the window, or listed after it: fetch it alone.
            :error ->
              found = Lei.Stripe.impl().retrieve_payment_intent(purchase.pi)
              {check_purchase(purchase, found, refunded), Map.put(fetched, purchase.pi, found)}
          end
        end)

      case Enum.find(fetched, fn {_pi, found} ->
             match?({:error, _}, found) and not missing?(found)
           end) do
        {pi, {:error, reason}} ->
          {:error, "could not retrieve #{pi}: #{inspect(reason)}"}

        nil ->
          recorded = MapSet.new(purchases, & &1.pi)

          grace_cutoff =
            DateTime.to_unix(now) - Keyword.get(opts, :grace_minutes, @grace_minutes) * 60

          stripe_purchases =
            Enum.filter(intents, fn i ->
              purchase_intent?(i) and i["status"] == "succeeded" and
                (i["created"] || 0) <= grace_cutoff
            end)

          # Split before reporting, not after: a probe is only ever excluded
          # from this branch, so one that did reach the ledger has already
          # been checked by check_purchase/3 above.
          {probes, uncredited} =
            stripe_purchases
            |> Enum.reject(&MapSet.member?(recorded, &1["id"]))
            |> Enum.split_with(&probe?/1)

          stripe_side =
            for i <- uncredited do
              discrepancy("received_not_recorded", i["id"], %{
                "amount_received" => i["amount_received"],
                "metadata" => i["metadata"]
              })
            end

          {:ok,
           %{
             ledger_purchases: length(purchases),
             stripe_purchases: length(stripe_purchases),
             probe_excluded: length(probes),
             discrepancies: List.flatten(ledger_side) ++ stripe_side
           }}
      end
    end
  end

  defp list_intents(since, opts, starting_after \\ nil, acc \\ [], page \\ 1) do
    max_pages = Keyword.get(opts, :max_pages, @max_pages)

    if page > max_pages do
      {:error, "more than #{max_pages} pages of PaymentIntents; not comparing a partial list"}
    else
      case Lei.Stripe.impl().list_payment_intents(since, starting_after) do
        {:ok, %{"data" => data, "has_more" => true}} when data != [] ->
          list_intents(since, opts, List.last(data)["id"], acc ++ data, page + 1)

        {:ok, %{"data" => data}} when is_list(data) ->
          {:ok, acc ++ data}

        {:ok, other} ->
          {:error, "unexpected list response: #{inspect(other) |> String.slice(0, 200)}"}

        {:error, reason} ->
          {:error, "could not list PaymentIntents: #{inspect(reason)}"}
      end
    end
  end

  defp check_purchase(purchase, found, refunded) do
    case found do
      {:ok, intent} ->
        charge = intent["latest_charge"]
        stripe_refunded = if is_map(charge), do: charge["amount_refunded"] || 0, else: 0
        ledger_refunded = Map.get(refunded, purchase.pi, 0)
        details = %{"rail" => purchase.rail, "ledger_cents" => purchase.cents}

        [
          intent["status"] != "succeeded" &&
            discrepancy(
              "not_succeeded",
              purchase.pi,
              Map.put(details, "status", intent["status"])
            ),
          (intent["status"] == "succeeded" and intent["amount_received"] != purchase.cents) &&
            discrepancy(
              "amount_mismatch",
              purchase.pi,
              Map.put(details, "stripe_cents", intent["amount_received"])
            ),
          (intent["currency"] || "usd") != "usd" &&
            discrepancy(
              "currency_mismatch",
              purchase.pi,
              Map.put(details, "currency", intent["currency"])
            ),
          intent["livemode"] != live?() &&
            discrepancy(
              "mode_mismatch",
              purchase.pi,
              Map.put(details, "livemode", intent["livemode"])
            ),
          stripe_refunded > ledger_refunded &&
            discrepancy(
              "refund_not_recorded",
              purchase.pi,
              Map.merge(details, %{
                "stripe_refunded" => stripe_refunded,
                "ledger_refunded" => ledger_refunded
              })
            )
        ]
        |> Enum.filter(& &1)

      found ->
        if missing?(found),
          do: [discrepancy("missing_in_stripe", purchase.pi, %{"rail" => purchase.rail})],
          else: []
    end
  end

  # Lei.Stripe returns a non-200 as {:error, {status, body}}: the shape
  # captured from production for an unknown PaymentIntent.
  defp missing?({:error, {404, %{"error" => %{"code" => "resource_missing"}}}}), do: true
  defp missing?(_), do: false

  defp purchase_intent?(%{"metadata" => %{} = meta}),
    do: Map.has_key?(meta, "challenge_id") or Map.has_key?(meta, "lei_rail")

  defp purchase_intent?(_), do: false

  # A probe is named, never inferred from shape: nothing about an amount or a
  # rail makes a payment a probe, so only the convention does. An empty prefix
  # excludes nothing, which is what an unconfigured deploy should do.
  defp probe?(%{"metadata" => %{"challenge_id" => id}}) when is_binary(id) do
    case probe_prefix() do
      "" -> false
      prefix -> String.starts_with?(id, prefix)
    end
  end

  defp probe?(_), do: false

  defp probe_prefix do
    Application.get_env(:lei_service, :reconciliation_probe_prefix, @probe_prefix) || ""
  end

  defp ledger_purchases(window_start) do
    since = DateTime.to_naive(window_start)

    from(e in CreditEntry,
      where:
        like(e.reason, "purchase:%") and e.inserted_at >= ^since and not is_nil(e.external_ref),
      select: %{external_ref: e.external_ref, reason: e.reason, cents: e.usd_value_cents}
    )
    |> Repo.all()
    |> Enum.flat_map(fn e ->
      case String.split(e.external_ref, ":", parts: 2) do
        [prefix, "pi_" <> _ = pi] when prefix in @purchase_prefixes ->
          [%{pi: pi, rail: String.replace_prefix(e.reason, "purchase:", ""), cents: e.cents}]

        _ ->
          []
      end
    end)
  end

  # What the ledger has recorded as refunded, in cents, per PaymentIntent: the
  # highest cumulative amount_refunded a refund reversal was written for.
  defp refunded_cents([]), do: %{}

  defp refunded_cents(purchases) do
    pis = Enum.map(purchases, & &1.pi)

    from(e in CreditEntry,
      where:
        like(e.reason, "reversal:%") and fragment("?->>'kind'", e.metadata) == "refund" and
          fragment("?->>'reverses'", e.metadata) in ^pis,
      select:
        {fragment("?->>'reverses'", e.metadata),
         fragment("(?->>'amount_refunded_cents')::bigint", e.metadata)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pi, cents}, acc ->
      Map.update(acc, pi, cents || 0, &max(&1, cents || 0))
    end)
  end

  defp discrepancy(kind, pi, details),
    do: Map.merge(details, %{"kind" => kind, "payment_intent" => pi})

  defp configured? do
    key = Application.get_env(:lei_service, :stripe_secret_key)
    is_binary(key) and key != ""
  end

  defp live?, do: Lei.Stripe.Mode.current() == :live

  # -- recording

  defp record(window_start, result) do
    attrs =
      case result do
        {:ok, %{discrepancies: found} = r} ->
          if found != [] do
            Logger.error(
              "Stripe reconciliation: #{length(found)} discrepancies, e.g. #{inspect(hd(found))}"
            )
          end

          %{
            status: if(found == [], do: "ok", else: "discrepancies"),
            ledger_purchases: r.ledger_purchases,
            stripe_purchases: r.stripe_purchases,
            probe_excluded: r.probe_excluded,
            discrepancy_count: length(found),
            discrepancies: Enum.take(found, @kept_discrepancies)
          }

        {:error, reason} ->
          Logger.error("Stripe reconciliation failed: #{reason}")
          %{status: "failed", error: reason, discrepancies: []}
      end

    %Run{}
    |> Ecto.Changeset.change(Map.put(attrs, :window_start, window_start))
    |> Repo.insert()
  end
end
