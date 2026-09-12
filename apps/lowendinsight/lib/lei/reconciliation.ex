defmodule Lei.Reconciliation do
  @moduledoc """
  Checks that the ledger and `analysis_usage` tell the same story.

  ## What can actually drift, after #112

  The issue that asked for this (#105) assumed a failed debit would leave a
  committed usage row with no ledger entry. That is no longer possible: the
  debit and the usage row are one transaction, so they commit together or not
  at all.

  What remains:

    * **pre-ledger usage.** Rows recorded before the ledger existed have no
      debits and never will. Expected, permanent, and counted separately rather
      than reported as a fault -- otherwise the check shows a constant non-zero
      drift and stops meaning anything.

    * **manual adjustments.** `adjustment:manual` entries deliberately move a
      balance without corresponding usage. Excluded from this comparison, which
      is only about `debit:analysis`.

    * **a genuine bug.** Which is the entire point. If the two diverge for any
      row recorded after the ledger began, something is wrong that nothing else
      would report.

  ## Telling Stripe is a separate question

  The meter report happens *outside* the transaction, deliberately: an HTTP
  call inside one holds a database connection for its duration. So the ledger
  and what Stripe has been told can diverge.

  `stripe_reporting/0` answers the half of that we can answer locally: did our
  call succeed, and was it made at all. The failure is under-billing -- usage
  debited, Stripe never told -- which errs against us rather than the customer
  and is still worth knowing.

  What it cannot see is Stripe's side: an event accepted and then lost or
  double-counted there. That needs Stripe's own data and a different mechanism.
  """

  import Ecto.Query

  alias Lei.{AnalysisUsage, CreditEntry, MeterReport, Org, Repo}

  @debit_reason "debit:analysis"

  @doc """
  Compares every usage row against the debits that reference it.

  Returns counts rather than rows. The aggregate is what monitoring needs, and
  the detail is available through `drifting_rows/1` when someone is actually
  investigating.
  """
  def usage_vs_credits do
    rows = rows_with_debits()
    started = ledger_started_at()

    {pre_ledger, reconcilable} =
      Enum.split_with(rows, fn row -> pre_ledger?(row, started) end)

    drifting = Enum.filter(reconcilable, &drifting?/1)

    %{
      ledger_started_at: started,
      usage_rows: length(rows),
      pre_ledger_rows: length(pre_ledger),
      reconciled_rows: length(reconcilable) - length(drifting),
      drifting_rows: length(drifting),
      drift_credits: drifting |> Enum.map(&drift/1) |> Enum.sum(),
      expected_credits: reconcilable |> Enum.map(& &1.expected) |> Enum.sum(),
      debited_credits: reconcilable |> Enum.map(& &1.debited) |> Enum.sum()
    }
  end

  @doc """
  Whether metered usage reached Stripe.

  Only Pro orgs with a Stripe customer are metered at all, so those are the
  only ones counted. `unreported` means a debit exists for a metered org with
  no corresponding meter report -- the call was never made, or the process died
  before it returned.
  """
  def stripe_reporting do
    metered_orgs = metered_org_ids()

    debits = debits_for_orgs(metered_orgs)
    reports = reports_by_usage_id()

    {reported, unreported} =
      Enum.split_with(debits, fn d -> Map.has_key?(reports, d.usage_id) end)

    failed =
      reported
      |> Enum.filter(fn d -> Map.get(reports, d.usage_id) == "failed" end)

    %{
      metered_orgs: length(metered_orgs),
      reported: length(reported) - length(failed),
      failed: length(failed),
      unreported: length(unreported),
      unreported_credits: unreported |> Enum.map(& &1.credits) |> Enum.sum()
    }
  end

  defp metered_org_ids do
    Repo.all(
      from(o in Org,
        where: o.tier == "pro" and not is_nil(o.stripe_customer_id),
        select: o.id
      )
    )
  end

  defp debits_for_orgs([]), do: []

  defp debits_for_orgs(org_ids) do
    Repo.all(
      from(e in CreditEntry,
        where: e.reason == ^@debit_reason,
        where: e.org_id in ^org_ids,
        where: not is_nil(fragment("?->>'analysis_usage_id'", e.metadata)),
        select: %{
          usage_id: fragment("(?->>'analysis_usage_id')::bigint", e.metadata),
          credits: fragment("-?", e.delta)
        }
      )
    )
    |> Enum.map(fn row -> Map.update!(row, :credits, &to_integer/1) end)
  end

  defp reports_by_usage_id do
    Repo.all(
      from(r in MeterReport,
        where: not is_nil(r.analysis_usage_id),
        select: {r.analysis_usage_id, r.status}
      )
    )
    |> Map.new()
  end

  @doc """
  The rows that do not reconcile, for someone investigating a non-zero drift.
  """
  def drifting_rows do
    started = ledger_started_at()

    rows_with_debits()
    |> Enum.reject(&pre_ledger?(&1, started))
    |> Enum.filter(&drifting?/1)
    |> Enum.map(fn row -> Map.put(row, :drift, drift(row)) end)
    |> Enum.sort_by(& &1.usage_id)
  end

  @doc """
  Whether the ledger and usage agree. Used by monitoring.
  """
  def reconciled? do
    usage_vs_credits().drifting_rows == 0
  end

  # One row per analysis_usage, with the credits actually debited against it.
  #
  # Debits carry the usage row's id in metadata rather than a foreign key,
  # because a credit entry is not owned by a usage row -- most entries have no
  # usage at all. The join is on that value.
  defp rows_with_debits do
    debits =
      from(e in CreditEntry,
        where: e.reason == ^@debit_reason,
        where: not is_nil(fragment("?->>'analysis_usage_id'", e.metadata)),
        group_by: fragment("(?->>'analysis_usage_id')::bigint", e.metadata),
        select: %{
          usage_id: fragment("(?->>'analysis_usage_id')::bigint", e.metadata),
          # Debits are stored negative; compare magnitudes.
          debited: fragment("-sum(?)", e.delta)
        }
      )

    # Postgres hands numeric aggregates back as Decimal regardless of the cast,
    # so integers are restored here rather than at every use. Money arithmetic
    # in this codebase is integer credits; a Decimal leaking through is how a
    # sum silently starts rounding.
    normalise = fn row ->
      row
      |> Map.update!(:expected, &to_integer/1)
      |> Map.update!(:debited, &to_integer/1)
    end

    Repo.all(
      from(u in AnalysisUsage,
        left_join: d in subquery(debits),
        on: d.usage_id == u.id,
        select: %{
          usage_id: u.id,
          org_id: u.org_id,
          period_start: u.period_start,
          updated_at: u.updated_at,
          # One credit is $0.001 and the usage row is in cents, so credits are
          # ten times the cost. A drift here would bill one amount and debit
          # another, which is why the ratio is asserted in tests rather than
          # assumed.
          expected: fragment("round(? * 10)::bigint", u.total_cost_cents),
          debited: coalesce(d.debited, 0)
        }
      )
    )
    |> Enum.map(normalise)
  end

  # Rows that predate the ledger have no debits and never will.
  #
  # The nil case defaults to excluding nothing, which is the opposite of the
  # first version of this function. Inferring the start from the earliest
  # credit entry meant an empty ledger made every row "pre-ledger" and the
  # check reported clean while reconciling nothing -- a check that passes by
  # examining nothing, which is the failure this whole module exists to catch.
  defp pre_ledger?(_row, nil), do: false

  defp pre_ledger?(row, started) do
    row.debited == 0 and NaiveDateTime.compare(row.updated_at, started) == :lt
  end

  defp drifting?(row), do: drift(row) != 0

  defp drift(row), do: row.expected - row.debited

  # When the ledger began, taken from when its table was created rather than
  # inferred from the data in it. The earliest credit entry is not the same
  # thing: entries can be absent, and a ledger with nothing in it is exactly
  # the case that must not silently excuse every row.
  @ledger_migration 20_260_911_000_001

  defp ledger_started_at do
    Repo.one(
      from(m in "schema_migrations",
        where: m.version == ^@ledger_migration,
        select: m.inserted_at
      )
    )
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d, 0))
  defp to_integer(n) when is_integer(n), do: n
end
