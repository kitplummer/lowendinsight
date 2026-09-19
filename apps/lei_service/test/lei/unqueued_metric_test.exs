defmodule Lei.UnqueuedMetricTest do
  @moduledoc """
  Work that was charged for and could not be queued is counted (#217).

  #233 and #234 made the money follow the work: a dependency or an analysis
  that never reached Oban is credited back. Nothing reported that it had
  happened, so a rising rate -- Oban schema drift, a database refusing the
  insert -- would be visible only to someone reading the ledger.

  Counted from the ledger rather than from a counter incremented at the point
  of failure. A process-local counter resets on boot and can disagree with what
  was actually written; `adjustment:unqueued` entries are the durable record of
  exactly the thing being counted, and cannot drift from it.

  Two windows. `all` is the total, for context. `1h` is what the monitor fails
  on: long enough that an incident does not vanish before anyone looks, short
  enough that the check goes green again without waiting a day.
  """
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Unqueued Metric #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    %{org: org}
  end

  defp gauge(body, window, measure) do
    case Regex.run(
           ~r/^lei_unqueued_credits\{window="#{window}",measure="#{measure}"\} (\d+)$/m,
           body
         ) do
      [_, value] -> String.to_integer(value)
      nil -> nil
    end
  end

  defp age!(entry, seconds) do
    entry
    |> Ecto.Changeset.change(
      inserted_at:
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-seconds, :second)
        |> NaiveDateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  test "reports zero when nothing has failed to queue" do
    body = Lei.Metrics.collect()

    assert gauge(body, "1h", "entries") == 0
    assert gauge(body, "1h", "credits") == 0
    assert gauge(body, "all", "entries") == 0
  end

  test "counts an entry and the credits it gave back", ctx do
    {:ok, _} = Credits.credit_unqueued(ctx.org.id, 250, %{"unqueued" => 5})

    body = Lei.Metrics.collect()

    assert gauge(body, "1h", "entries") == 1
    assert gauge(body, "1h", "credits") == 250
    assert gauge(body, "all", "entries") == 1
  end

  # The window is the point: an incident an hour ago should stop failing the
  # monitor, while the total keeps the history.
  test "an older entry leaves the window but stays in the total", ctx do
    {:ok, entry} = Credits.credit_unqueued(ctx.org.id, 250, %{"unqueued" => 5})
    age!(entry, 2 * 60 * 60)

    body = Lei.Metrics.collect()

    assert gauge(body, "1h", "entries") == 0
    assert gauge(body, "all", "entries") == 1
    assert gauge(body, "all", "credits") == 250
  end

  test "other ledger entries are not counted as unqueued work", ctx do
    {:ok, _} =
      Credits.grant(ctx.org.id, 100, "adjustment:manual",
        external_ref: "m-#{System.unique_integer([:positive])}"
      )

    {:ok, _} =
      Credits.debit(ctx.org.id, 10, "debit:analysis",
        external_ref: "d-#{System.unique_integer([:positive])}"
      )

    assert gauge(Lei.Metrics.collect(), "all", "entries") == 0
  end

  describe "something reads it" do
    @monitor Path.expand("../../../../.github/workflows/monitor.yml", __DIR__)

    test "the monitor fails on work that could not be queued" do
      monitor = File.read!(@monitor)

      assert monitor =~ ~s(lei_unqueued_credits{window="1h",measure="entries"})

      assert monitor =~ ~r/UNQUEUED:-0\}" -gt 0/,
             "the gauge is read but never compared, so nothing fails on it"

      assert monitor =~ "::error::${UNQUEUED}",
             "a rise in unqueued work must fail the check, not print a note"
    end

    test "the family is asserted present, so a vanished collector is not read as zero" do
      assert File.read!(@monitor) =~ "lei_unqueued_credits"
    end
  end
end
