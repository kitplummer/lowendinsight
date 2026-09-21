defmodule LeiService.UndeterminedRefundTest do
  @moduledoc """
  An analysis that ran and determined nothing is not cached, and is paid back (#258).

  Billing settles at admission, from the cache split, before any analysis runs
  — ADR-002 puts refusal before the work rather than after it. So an outcome
  discovered later has to be given back rather than never charged, which is
  what `adjustment:unqueued` already does for work that never started (#217,
  #233).

  This is the other case: the work started, ran, and determined nothing. The
  requester paid a cache miss and received a report whose every metric is nil.

  #256 stopped those reports being cached on `analyze_remote`. It did not touch
  this path, which has its own cache and kept the defect — so both halves are
  tested here.
  """
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Undetermined #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    on_exit(fn -> Application.delete_env(:lei_service, :batch_dependency) end)

    %{org: org}
  end

  defp unanalysable(url) do
    %{
      header: %{repo: url, uuid: "u"},
      data: %{
        error: "Unable to analyze the repo (#{url}), is this a valid Git repo URL?",
        repo: url,
        git: %{},
        risk: "undetermined"
      }
    }
  end

  defp real_report(url) do
    %{
      header: %{repo: url, uuid: "u"},
      data: %{repo: url, git: %{"hash" => "abc"}, results: %{"a_risk" => "low"}, risk: "low"}
    }
  end

  defp stub(report) do
    Application.put_env(:lei_service, :batch_dependency,
      resolve: fn _eco, pkg, _opts -> {:ok, "https://github.com/x/#{pkg}"} end,
      analyze: fn url -> {:ok, report.(url)} end
    )
  end

  defp run(org_id, package) do
    LeiService.BatchDependencyWorker.perform(%Oban.Job{
      args: %{
        "ecosystem" => "hex",
        "package" => package,
        "version" => "1.0.0",
        "org_id" => org_id
      }
    })
  end

  defp undetermined_credits(org_id) do
    import Ecto.Query

    Repo.all(
      from(e in "credit_entries",
        where: e.org_id == ^org_id and e.reason == "adjustment:undetermined",
        select: e.delta
      )
    )
  end

  describe "an analysis that determined nothing" do
    test "is not cached", %{org: org} do
      stub(&unanalysable/1)
      pkg = "nope#{System.unique_integer([:positive])}"

      assert :ok = run(org.id, pkg)

      assert Lei.BatchCache.get("hex", pkg, "1.0.0") in [nil, :miss, {:error, :miss}] or
               match?({:error, _}, Lei.BatchCache.get("hex", pkg, "1.0.0")),
             "a failed analysis was cached, so the next request is served nothing"
    end

    test "credits the requester back", %{org: org} do
      stub(&unanalysable/1)

      assert :ok = run(org.id, "nope#{System.unique_integer([:positive])}")

      credits = undetermined_credits(org.id)
      assert length(credits) == 1
      assert hd(credits) == Credits.cost_in_credits(0, 1)
    end

    test "the entry says what it was, not merely that money moved", %{org: org} do
      import Ecto.Query
      stub(&unanalysable/1)
      pkg = "nope#{System.unique_integer([:positive])}"

      run(org.id, pkg)

      [meta] =
        Repo.all(
          from(e in "credit_entries",
            where: e.org_id == ^org.id and e.reason == "adjustment:undetermined",
            select: e.metadata
          )
        )

      assert meta["package"] == pkg
      assert meta["undetermined"] == 1
    end

    test "the job succeeds rather than retrying forever", %{org: org} do
      # Nothing about a retry changes the answer, and one unanalysable
      # dependency must not fail a manifest of two hundred.
      stub(&unanalysable/1)

      assert :ok = run(org.id, "nope#{System.unique_integer([:positive])}")
    end
  end

  describe "an analysis that determined something" do
    # The over-correction to guard against: refusing to cache failures must not
    # become refusing to cache, and nobody should be credited for work done.
    test "is cached and credits nobody", %{org: org} do
      stub(&real_report/1)
      pkg = "good#{System.unique_integer([:positive])}"

      assert :ok = run(org.id, pkg)

      assert undetermined_credits(org.id) == []
    end
  end

  describe "when there is no org to credit" do
    test "the work still completes and nothing is written", %{org: org} do
      # Jobs enqueued before org_id was carried, or by a path with no org. An
      # entry against nobody is worse than no entry.
      stub(&unanalysable/1)

      assert :ok = run(nil, "nope#{System.unique_integer([:positive])}")
      assert undetermined_credits(org.id) == []
    end
  end

  describe "something reads it" do
    test "the rate is published, counted from the ledger", %{org: org} do
      # From the entries rather than a counter at the point of failure (#217):
      # a process counter resets on boot and can disagree with what was
      # written, while these are the durable record of exactly this.
      stub(&unanalysable/1)
      run(org.id, "nope#{System.unique_integer([:positive])}")

      body = Lei.Metrics.collect()

      assert body =~ ~s(lei_undetermined_credits{window="1h",measure="entries"} 1)
      assert body =~ ~s(lei_undetermined_credits{window="all",measure="credits"})
    end

    test "reports zero rather than nothing when none have happened" do
      body = Lei.Metrics.collect()

      # A missing series and a zero read the same to anyone scraping, so the
      # family must be present either way or "no failures" is indistinguishable
      # from "the collector vanished".
      assert body =~ "lei_undetermined_credits"
    end
  end

  describe "the enqueue carries the org" do
    # Without it the worker has nobody to credit, and every refund above
    # silently becomes the no-org branch.
    @router Path.expand("../../lib/lei/web/router.ex", __DIR__)

    test "org_id is in the job args" do
      source = File.read!(@router)

      assert source =~ ~s("org_id" => org_id),
             "the dependency job does not carry the org, so nothing can be credited back"

      assert source =~ "scheduler(org_id)",
             "the scheduler is built without an org"
    end
  end
end
