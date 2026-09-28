defmodule LeiService.ScanCostTest do
  @moduledoc """
  The cost of scanning the miss list, and the ways that number could be wrong
  while looking right.

  A cost estimate is quoted. It gets put in a plan, and nobody re-derives it. So
  each way it could flatter us has a test: a sample too small to mean anything, a
  sample where the failures were averaged away, a rate card with a line missing
  treated as free.
  """
  use ExUnit.Case, async: true

  alias LeiService.CacheBaseline, as: Baseline
  alias LeiService.ScanCost

  defp sample(seconds, clone_mb, report_kb) do
    %{
      seconds: seconds,
      clone_bytes: round(clone_mb * 1_000_000),
      report_bytes: round(report_kb * 1_000)
    }
  end

  describe "the per-repository measurement" do
    test "median and mean are both reported, because they disagree here" do
      # The 2026-09-20 unit cost record measured a median clone of 4.6 MB and a
      # mean of 7.9 MB. Quoting one number for a population that skewed hides
      # which repositories drive the bill.
      samples = [sample(0.5, 1, 3), sample(0.7, 2, 4), sample(8.0, 50, 100)]

      per_repo = ScanCost.per_repository(samples, 0)

      assert per_repo.seconds.median == 0.7
      assert_in_delta per_repo.seconds.mean, 3.07, 0.01
      assert per_repo.seconds.max == 8.0
      assert per_repo.clone_bytes.max == 50_000_000
    end

    test "failures are counted, not averaged away" do
      # A sample where the clones failed has a flattering mean: the failures
      # contribute nothing. The count and rate travel with the numbers so the
      # caller can see the sample was degraded.
      per_repo = ScanCost.per_repository([sample(1.0, 5, 10)], 3)

      assert per_repo.sampled == 1
      assert per_repo.failed == 3
      assert per_repo.failure_rate == 75.0
    end

    test "nothing sampled gives no failure rate, not 0%" do
      per_repo = ScanCost.per_repository([], 0)

      assert per_repo.failure_rate == nil
      assert per_repo.seconds.mean == nil
    end
  end

  describe "extrapolating to the corpus" do
    test "an unmeasurable sample does not produce an estimate" do
      # The shape this codebase keeps shipping is a number where there is no
      # measurement. Zero sampled repositories must not extrapolate to zero cost.
      estimate = ScanCost.extrapolate(50_000, ScanCost.per_repository([], 0))

      refute estimate.measurable
      refute Map.has_key?(estimate, :one_pass)
    end

    test "one pass scales with the corpus, and wall clock divides by concurrency" do
      per_repo = ScanCost.per_repository([sample(1.0, 8, 25)], 0)
      estimate = ScanCost.extrapolate(1000, per_repo, concurrency: 5)

      assert estimate.one_pass.cpu_seconds == 1000.0
      assert estimate.one_pass.wall_clock_seconds == 200.0
      assert estimate.one_pass.ingress_bytes == 8_000_000_000
      assert estimate.one_pass.stored_bytes == 25_000_000
    end

    test "the naive month re-analyses everything and the watched month only what moved" do
      # This gap is the argument for the watch model, and it has to be visible in
      # the same output or it is an argument nobody can check. With a 30-day TTL
      # the whole corpus expires monthly whether or not it changed.
      per_repo = ScanCost.per_repository([sample(1.0, 8, 25)], 0)
      estimate = ScanCost.extrapolate(1000, per_repo, churn: 0.4, ttl_days: 30)

      assert estimate.naive_monthly.analyses == 1000
      assert estimate.watched_monthly.analyses == 400

      assert estimate.watched_monthly.ingress_bytes < estimate.naive_monthly.ingress_bytes,
             "watching did not reduce ingress, which is the only reason to build it"

      assert estimate.watched_monthly.probes == 30_000
    end

    test "a shorter TTL costs more passes a month" do
      per_repo = ScanCost.per_repository([sample(1.0, 8, 25)], 0)

      assert ScanCost.extrapolate(100, per_repo, ttl_days: 15).naive_monthly.analyses == 200
      assert ScanCost.extrapolate(100, per_repo, ttl_days: 30).naive_monthly.analyses == 100
    end

    test "the assumptions are carried with the estimate" do
      # An estimate whose churn and concurrency are not stated is unreproducible,
      # and the first question anyone asks of a cost is what it assumed.
      estimate = ScanCost.extrapolate(10, ScanCost.per_repository([sample(1.0, 8, 25)], 0))

      assert estimate.assumptions.churn
      assert estimate.assumptions.concurrency
      assert estimate.assumptions.ttl_days
    end
  end

  describe "pricing" do
    @rates %{"cpu_hour" => 0.10, "ingress_gb" => 0.02, "storage_gb_month" => 0.30}

    test "quantities times rates, per line" do
      quantities = %{cpu_seconds: 3600.0, ingress_bytes: 1_000_000_000, stored_bytes: 0}

      priced = ScanCost.price(quantities, @rates)

      assert priced.usd.cpu == 0.1
      assert priced.usd.ingress == 0.02
      assert priced.total_usd == 0.12
    end

    test "a missing rate leaves its line out and says so, rather than costing nothing" do
      # A rate we do not have, treated as zero, silently removes a cost from a
      # total that still looks like a total.
      quantities = %{cpu_seconds: 3600.0, ingress_bytes: 1_000_000_000, stored_bytes: 0}

      priced = ScanCost.price(quantities, %{"cpu_hour" => 0.10})

      refute Map.has_key?(priced.usd, :ingress)
      assert "ingress_gb" in priced.missing
      assert "storage_gb_month" in priced.missing
    end
  end

  describe "the miss list" do
    defp entry(package, repository),
      do: %{ecosystem: "npm", package: package, repository: repository}

    test "is the repositories we resolved and do not hold" do
      resolved = [
        entry("a", {:ok, "https://github.com/o/a"}),
        entry("b", {:ok, "https://github.com/o/b"}),
        entry("c", {:error, :no_repository})
      ]

      missing = Baseline.missing(resolved, MapSet.new(["https://github.com/o/a"]))

      assert missing == ["https://github.com/o/b"]
    end

    test "a repository many packages share appears once" do
      # It is one clone and one report however many packages point at it.
      # Counting it per package would inflate the preload cost by the shape of
      # the manifest rather than the work.
      resolved = [
        entry("a", {:ok, "https://github.com/o/mono"}),
        entry("b", {:ok, "https://github.com/o/mono"})
      ]

      assert Baseline.missing(resolved, MapSet.new()) == ["https://github.com/o/mono"]
    end

    test "it is in the summary, because a count cannot be sampled" do
      resolved = [entry("a", {:ok, "https://github.com/o/a"})]

      summary = Baseline.summarise(resolved, MapSet.new(), ["o/r"], %{}, "all")

      assert summary.repositories_missing == ["https://github.com/o/a"]
    end
  end

  describe "the resolver contract" do
    test "a resolver returning the entry instead of the resolution fails loudly" do
      # This shipped. The Mix task's resolver returned the entry with :repository
      # already set, resolve_all set :repository to that whole entry, nothing
      # matched {:ok, url}, and the run reported "Probing 0 repositories" and a
      # coverage of 0% as though those were findings. The tests passed throughout
      # because they supply their own resolver.
      entries = [%{ecosystem: "npm", package: "a"}]

      resolved =
        Baseline.resolve_all(entries, fn entry -> Map.put(entry, :repository, {:ok, "x"}) end)

      assert [%{repository: {:error, {:crashed, message}}}] = resolved
      assert message =~ "expected {:ok, url} or {:error, reason}"
    end

    test "a well-behaved resolver is untouched" do
      resolved =
        Baseline.resolve_all([%{ecosystem: "npm", package: "a"}], fn _ ->
          {:ok, "https://github.com/o/a"}
        end)

      assert [%{repository: {:ok, "https://github.com/o/a"}}] = resolved
    end
  end

  describe "the scheduled run costs what it measured" do
    # A baseline with no cost beside it is a count, and the question that follows
    # a count is always what it would cost. These are the flags that stop a
    # degraded sample from becoming a quoted price.
    @workflow Path.expand("../../../../.github/workflows/cache-baseline.yml", __DIR__)

    setup do
      %{yaml: File.read!(@workflow)}
    end

    test "the cost step runs against the baseline it just produced", %{yaml: yaml} do
      assert yaml =~ "lei.scan_cost"
      assert yaml =~ "--baseline baseline.json"
    end

    test "a step that pipes into tee sets pipefail", %{yaml: yaml} do
      # `| tee` returns tee's status. Without pipefail, mix raised
      # "LEI_JWT_SECRET env var is required in production", tee exited 0, and
      # every step of the run reported success having measured nothing
      # (2026-09-28) -- the failure shape the measurement exists to avoid,
      # inside the thing built to avoid it. Checked across the whole file rather
      # than at the two places it is written today, so a pipeline added later is
      # covered.
      blocks = String.split(yaml, ~r/^      - name: /m)

      Enum.each(blocks, fn block ->
        if String.contains?(block, "| tee") do
          assert String.contains?(block, "set -o pipefail"),
                 "a step pipes into tee without pipefail, so a failure in it would be invisible:\n#{block}"
        end
      end)
    end

    test "it does not run under MIX_ENV=prod", %{yaml: yaml} do
      # Starting the app under prod demands LEI_JWT_SECRET and the rest, and a CI
      # runner has none of them. config/gha.exs is the environment built for CI
      # with no Postgres and no Redis.
      refute yaml =~ "MIX_ENV: prod",
             "the measurement runs in an environment that requires production secrets"

      assert yaml =~ "MIX_ENV: gha"
    end

    test "a run with no hit rate in it fails the job", %{yaml: yaml} do
      # The summary step runs `if: always()`. Writing a sad heading and exiting 0
      # is how a job that measured nothing stays green, which is what happened.
      # The check reads the JSON, because tee writes the text file even for a run
      # that raised halfway through.
      assert yaml =~ ~r/hit_rate != null/,
             "nothing in the job asserts that a hit rate was actually measured"

      assert yaml =~ "exit 1"
    end

    test "the cost output is kept, not just printed", %{yaml: yaml} do
      # The JSON carries the per-repository sample. Without it, a cost that looks
      # wrong six weeks later cannot be checked against what it was measured on.
      assert yaml =~ "cost.json"
    end
  end
end
