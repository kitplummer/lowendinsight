defmodule Lei.Payments.ChallengeReaperTest do
  use ExUnit.Case, async: false

  alias Lei.Payments.{ChallengeReaper, ChallengeStore}
  alias Lei.Payments.Mpp.Challenge
  alias Lei.Payments.Rails.Mpp
  alias Lei.Wallets

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    address = "0x" <> String.duplicate("c", 39) <> "3"
    {:ok, org} = Wallets.provision(address)

    %{org: org}
  end

  defp store(org, expires) do
    challenge =
      Challenge.new(
        realm: "lowendinsight.dev",
        request: %{"amount" => "1500", "currency" => "usd", "credits" => 15_000},
        expires: expires
      )

    {:ok, _record} = ChallengeStore.put(challenge, org.id, Mpp)
    challenge
  end

  test "removes challenges that expired unanswered", %{org: org} do
    # An agent asking the price and walking away is normal, and each one is a
    # row. Left alone the table only grows.
    expired = store(org, DateTime.add(DateTime.utc_now(), -3600, :second))

    assert ChallengeReaper.purge() >= 1
    assert {:error, :unknown_challenge} = ChallengeStore.fetch(expired.id)
  end

  test "leaves challenges that have not expired", %{org: org} do
    live = store(org, DateTime.add(DateTime.utc_now(), 3600, :second))

    ChallengeReaper.purge()

    assert {:ok, _challenge, _record} = ChallengeStore.fetch(live.id)
  end

  test "keeps settled challenges even once expired", %{org: org} do
    # They are the record that a payment was asked for and answered, and what
    # makes "issued and never paid" a number rather than a guess.
    settled = store(org, DateTime.add(DateTime.utc_now(), -3600, :second))
    {:ok, _challenge, record} = ChallengeStore.fetch(settled.id)
    {:ok, _} = ChallengeStore.mark_settled(record)

    ChallengeReaper.purge()

    assert {:ok, _challenge, _record} = ChallengeStore.fetch(settled.id)
  end

  test "purging an empty table is not an error" do
    assert ChallengeReaper.purge() == 0
  end

  test "it is supervised" do
    # The cleanup existing is not the same as it running. Nothing called
    # purge_expired/1 before this process did.
    assert is_pid(Process.whereis(ChallengeReaper))
  end

  test "an unexpected message does not take it down" do
    pid = Process.whereis(ChallengeReaper)
    send(pid, :something_else)

    # Nothing depends on this process; crashing the tree over a stray message
    # would be worse than a stale row.
    assert Process.alive?(pid)
  end
end
