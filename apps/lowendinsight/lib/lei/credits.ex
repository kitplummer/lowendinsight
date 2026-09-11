defmodule Lei.Credits do
  @moduledoc """
  The credit ledger. See ADR-002.

  One credit is $0.001 -- a tenth of a cent -- which is the same unit the Stripe
  meter already reports in, so the two are directly comparable without a
  conversion step to get wrong. From ADR-001's pricing:

    cache hit   $0.005  =   5 credits
    cache miss  $0.05   =  50 credits

  All arithmetic here is integer. No Decimal, no floats: money that rounds is
  money that drifts, and a ledger whose sum depends on evaluation order is not
  a ledger.
  """

  import Ecto.Query
  alias Lei.{Repo, CreditEntry}

  @credits_per_cache_hit 5
  @credits_per_cache_miss 50

  def credits_per_cache_hit, do: @credits_per_cache_hit
  def credits_per_cache_miss, do: @credits_per_cache_miss

  @doc """
  Credits owed for a number of cache hits and misses.
  """
  def cost_in_credits(cache_hits, cache_misses)
      when is_integer(cache_hits) and is_integer(cache_misses) do
    cache_hits * @credits_per_cache_hit + cache_misses * @credits_per_cache_miss
  end

  @doc """
  Current balance for an org: the sum of every delta.

  Returns 0 for an org with no entries -- `sum` over an empty set is NULL in
  SQL, and a nil balance propagating into a comparison is how a zero-balance
  org gets served for free.
  """
  def balance(org_id) do
    Repo.one(
      from(e in CreditEntry,
        where: e.org_id == ^org_id,
        select: coalesce(sum(e.delta), 0)
      )
    )
    |> to_integer()
  end

  @doc """
  Add credits. `credits` must be positive.

  Options: `:external_ref`, `:usd_value_cents`, `:jurisdiction`, `:metadata`.

  `:usd_value_cents` is the USD value at the moment of receipt, which is not
  necessarily the face value of the credits granted -- see ADR-002's accounting
  section. Recording only one of the two makes the difference unrecoverable.
  """
  def grant(org_id, credits, reason, opts \\ []) when is_integer(credits) and credits > 0 do
    insert_entry(org_id, credits, reason, opts)
  end

  @doc """
  Remove credits. `credits` must be positive; the entry is written negative.

  A debit is allowed to take the balance below zero. The alternative is
  refusing to record consumption that already happened, which loses the
  liability rather than resolving it. Callers that need to refuse service check
  the balance *before* doing the work.
  """
  def debit(org_id, credits, reason, opts \\ []) when is_integer(credits) and credits > 0 do
    insert_entry(org_id, -credits, reason, opts)
  end

  @doc """
  Entries for an org, newest first.
  """
  def entries(org_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from(e in CreditEntry,
        where: e.org_id == ^org_id,
        order_by: [desc: e.id],
        limit: ^limit
      )
    )
  end

  defp insert_entry(org_id, delta, reason, opts) do
    attrs = %{
      org_id: org_id,
      delta: delta,
      reason: reason,
      external_ref: Keyword.get(opts, :external_ref),
      usd_value_cents: Keyword.get(opts, :usd_value_cents),
      jurisdiction: Keyword.get(opts, :jurisdiction),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %CreditEntry{}
    |> CreditEntry.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      # The unique index on external_ref rejected this. That is the expected
      # outcome of a replayed webhook or a resubmitted payment proof, not a
      # failure -- report it as such so callers can tell "already credited"
      # apart from "could not credit".
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :external_ref) do
          {:error, :duplicate}
        else
          {:error, changeset}
        end
    end
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
end
