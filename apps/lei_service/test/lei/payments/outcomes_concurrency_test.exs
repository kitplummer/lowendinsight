defmodule Lei.Payments.OutcomesConcurrencyTest do
  @moduledoc """
  Payment attempts counted at the same moment are each counted (#139).

  Every attempt in the same hour, rail, outcome and reason lands on one row. A
  read-then-write increment loses counts when two attempts overlap, and the
  attempts that overlap most are the ones worth counting: a burst of forged
  credentials. The increment is a single upsert.

  Not in the SQL sandbox, which runs one query at a time and so would serialise
  exactly the overlap under test (see `Lei.AdmissionConcurrencyTest`).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.Repo
  alias Lei.Payments.Outcomes

  # A rail name no other test uses, so cleanup cannot touch real rows.
  @rail "concurrency-test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from(b in Outcomes.Bucket, where: b.rail == @rail))
    end)

    :ok
  end

  test "overlapping increments of one bucket lose none" do
    now = DateTime.utc_now()

    1..4
    |> Enum.map(fn _ ->
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        for _ <- 1..25, do: :ok = Outcomes.record(@rail, "refused", "challenge_mismatch", now)
      end)
    end)
    |> Enum.each(&Task.await(&1, 30_000))

    assert Repo.one(
             from(b in Outcomes.Bucket,
               where: b.rail == @rail,
               select: type(sum(b.count), :integer)
             )
           ) == 100
  end
end
