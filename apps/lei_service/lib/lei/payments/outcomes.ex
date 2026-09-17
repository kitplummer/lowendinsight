defmodule Lei.Payments.Outcomes do
  @moduledoc """
  Counts what happens on the payment path, by rail (#139, stage F).

    issued        a challenge offered on a rail
    unavailable   a rail that could not offer one, and why
    presented     a credential presented for settlement
    settled       a challenge settled for the first time; reason "retry" when
                  a settled challenge's credential is presented again
    refused       a credential that did not settle, and why
    rate_limited  a challenge or settle refused by rate limit (reason: which)

  `presented` is counted before the attempt and `settled`/`refused` after it,
  so presented minus the two is attempts that raised part-way.

  Postgres, in hourly buckets, not process memory: the service deploys several
  times a day, and "settled nothing in the last 24 hours" is only answerable if
  the count survives a restart. `/metrics` reports the last 24 hours.

  A refusal reason is the error's name (`{:payment_not_settled, "processing"}`
  counts as `payment_not_settled`), never its detail, which can come from the
  caller and would make a series per distinct value.

  Counting never decides a payment: a failure to record is logged and the
  attempt carries on.
  """

  import Ecto.Query
  require Logger

  alias Lei.Repo

  @retention_days 30

  defmodule Bucket do
    @moduledoc false
    use Ecto.Schema

    schema "payment_outcome_buckets" do
      field(:hour, :utc_datetime)
      field(:rail, :string)
      field(:outcome, :string)
      field(:reason, :string, default: "")
      field(:count, :integer, default: 0)
    end
  end

  @doc "Counts one outcome in the hour containing `at`."
  def record(rail, outcome, reason \\ nil, at \\ DateTime.utc_now()) do
    row = %{
      hour: hour(at),
      rail: to_string(rail),
      outcome: to_string(outcome),
      reason: reason_name(reason),
      count: 1
    }

    Repo.insert_all(Bucket, [row],
      on_conflict: [inc: [count: 1]],
      conflict_target: [:hour, :rail, :outcome, :reason]
    )

    :ok
  rescue
    error ->
      Logger.error(
        "Could not count payment outcome #{inspect({rail, outcome, reason})}: #{inspect(error)}"
      )

      :ok
  end

  @doc """
  Counts over the last `hours` hours, including the current one, as
  `%{rail, outcome, reason, count}`.
  """
  def summary(hours \\ 24, now \\ DateTime.utc_now()) do
    since = DateTime.add(hour(now), -(hours - 1) * 3600, :second)

    Repo.all(
      from(b in Bucket,
        where: b.hour >= ^since,
        group_by: [b.rail, b.outcome, b.reason],
        select: %{
          rail: b.rail,
          outcome: b.outcome,
          reason: b.reason,
          count: type(sum(b.count), :integer)
        }
      )
    )
  end

  @doc "Deletes buckets older than #{@retention_days} days. Returns how many."
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)
    {count, _} = Repo.delete_all(from(b in Bucket, where: b.hour < ^cutoff))
    count
  end

  @doc "The name a refusal is counted under."
  def reason_name(nil), do: ""
  def reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_name(reason) when is_binary(reason), do: reason
  def reason_name({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  def reason_name(_), do: "other"

  defp hour(%DateTime{} = at) do
    %{DateTime.truncate(at, :second) | minute: 0, second: 0}
  end
end
