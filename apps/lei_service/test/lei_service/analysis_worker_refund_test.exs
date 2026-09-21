defmodule LeiService.AnalysisWorkerRefundTest do
  @moduledoc """
  The other analysis path credits back too (#258).

  #268 covered the batch dependency worker. `analyze_remote` was left: it
  returned an undetermined report and nothing gave the money back, because the
  job carried no org. Admission charged a cache miss before the work ran, so
  the requester paid for a report whose every metric is nil.

  Counted from the finished report rather than tracked during the run. The
  report is what the requester received, so the refund cannot disagree with
  what they were given.
  """
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("WorkerRefund #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    %{org: org}
  end

  defp undetermined(url) do
    %{
      data: %{
        error: "Unable to analyze the repo (#{url}), is this a valid Git repo URL?",
        repo: url,
        git: %{},
        risk: "undetermined"
      }
    }
  end

  defp analysed(url) do
    %{data: %{repo: url, git: %{"hash" => "abc"}, results: %{"a_risk" => "low"}, risk: "low"}}
  end

  defp refund_for(org_id) do
    import Ecto.Query

    Repo.all(
      from(e in "credit_entries",
        where: e.org_id == ^org_id and e.reason == "adjustment:undetermined",
        select: {e.delta, e.metadata}
      )
    )
  end

  # The private refund runs off the report the worker receives, so it is driven
  # here through the same shape process/3 builds.
  defp report(repos), do: %{report: %{repos: repos}}

  defp run(report, org_id) do
    :erlang.apply(LeiService.AnalysisWorker, :refund_undetermined, [report, org_id])
  end

  describe "a report containing analyses that determined nothing" do
    test "credits back one miss for each", %{org: org} do
      run(report([undetermined("a"), undetermined("b"), analysed("c")]), org.id)

      assert [{delta, meta}] = refund_for(org.id)
      assert delta == Credits.cost_in_credits(0, 2)
      assert meta["undetermined"] == 2
    end

    test "credits nothing when every analysis determined something", %{org: org} do
      run(report([analysed("a"), analysed("b")]), org.id)

      assert refund_for(org.id) == []
    end

    test "an empty report credits nothing", %{org: org} do
      # A report with no repositories is not two hundred failures.
      run(report([]), org.id)

      assert refund_for(org.id) == []
    end
  end

  describe "cache hits, which decode to structs" do
    test "are counted as determined rather than crashing", %{org: org} do
      # A hit decodes to %RepoReport{}, and structs do not implement Access.
      # determined?/1 read `report[:data]` until this change, which raised
      # UndefinedFunctionError on exactly the reports it is asked about most.
      hit = %RepoReport{data: %Data{results: %Results{}}}

      run(report([hit, undetermined("b")]), org.id)

      assert [{delta, _}] = refund_for(org.id)
      assert delta == Credits.cost_in_credits(0, 1), "the cached hit was counted as a failure"
    end
  end

  describe "when there is no org" do
    test "nothing is written", %{org: org} do
      # An unauthenticated free analysis has no org. An entry against nobody is
      # worse than no entry.
      run(report([undetermined("a")]), nil)

      assert refund_for(org.id) == []
    end
  end

  describe "the job carries the org" do
    # Without it every refund above silently becomes the no-org branch.
    @supervisor Path.expand("../../lib/lei_service/analysis_supervisor.ex", __DIR__)
    @endpoint Path.expand("../../lib/lei_service/endpoint.ex", __DIR__)

    test "both enqueue paths include org_id" do
      # perform_analysis/4 and enqueue/4 build their own args. Asserting the
      # string appears at all is satisfied by either one, so both are counted:
      # dropping it from one path silently sends half the work unattributed.
      source = File.read!(@supervisor)
      occurrences = source |> String.split("org_id: org_id") |> length() |> Kernel.-(1)

      assert occurrences == 2,
             "expected both enqueue paths to carry the org, found #{occurrences}"
    end

    test "perform/1 actually calls the refund" do
      # The refund is tested directly above, so deleting this call site would
      # leave every one of those tests passing while no refund ever happened.
      worker = File.read!(Path.expand("../../lib/lei_service/analysis_worker.ex", __DIR__))

      assert worker =~ "refund_undetermined(report, args[\"org_id\"])",
             "the worker computes a report and never refunds against it"
    end

    test "the endpoint puts the admitted org into opts" do
      assert File.read!(@endpoint) =~ "org_id: billing_org(billing)"
    end
  end
end
