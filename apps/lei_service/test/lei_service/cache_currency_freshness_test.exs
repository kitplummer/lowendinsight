defmodule LeiService.CacheCurrencyFreshnessTest do
  @moduledoc """
  A cached report's commit currency is recomputed on the way out (#242).

  `commit_currency_risk` is the only one of the six risk metrics that reads the
  clock. It was stored as a number at analysis time and served unchanged for
  the life of the cache entry, so a repository drifting into abandonment was
  reported at the risk level it held up to 30 days ago -- and unbounded on the
  `any_age` path. A dependency going quiet is the thing this product exists to
  detect, so the cache was hiding precisely the signal it sells.

  Every report here stores a `last_commit_date` that disagrees with the frozen
  `commit_currency_weeks` beside it. That is exactly the state a real entry
  reaches by sitting in Redis: the raw input is still true, the derived verdict
  has gone out of date. Serving the derived one is the bug.

  Thresholds are the configured ones, not `RiskLogic`'s in-function fallbacks:
  26 weeks low->medium, 52 medium->high, 104 high->critical
  (`config/config.exs:73-77`, `config/runtime.exs:95-100`).
  """
  use ExUnit.Case, async: false

  alias LeiService.Datastore

  defp url, do: "https://github.com/lei-test/currency-#{System.unique_integer([:positive])}"

  defp weeks_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 7 * 86_400, :second) |> DateTime.to_iso8601()

  # A report as it looks after sitting in the cache: `stored_weeks` is what was
  # true when it was written, `last_commit_date` is what is still true now.
  defp cached_report(opts) do
    results =
      %{
        "commit_currency_weeks" => Keyword.fetch!(opts, :stored_weeks),
        "commit_currency_risk" => Keyword.fetch!(opts, :stored_risk),
        "contributor_count" => 12,
        "contributor_risk" => Keyword.get(opts, :contributor_risk, "low"),
        "functional_contributors" => 6,
        "functional_contributors_risk" => "low",
        "large_recent_commit_risk" => "low",
        "sbom_risk" => "low"
      }

    git =
      case Keyword.fetch(opts, :last_commit_weeks_ago) do
        {:ok, n} ->
          %{
            "hash" => "abc123",
            "default_branch" => "main",
            "last_commit_date" => weeks_ago(n),
            "total_commits_on_default_branch" => 40
          }

        :error ->
          Keyword.get(opts, :git, %{})
      end

    %{
      "header" => %{
        "repo" => "https://example.com/r",
        "end_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "start_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "uuid" => "u-1"
      },
      "data" => %{
        "repo" => "https://example.com/r",
        "git" => git,
        "results" => results,
        "risk" => Keyword.get(opts, :stored_toplevel, Keyword.fetch!(opts, :stored_risk))
      }
    }
  end

  defp put_and_read(opts) do
    u = url()
    {:ok, _} = Datastore.write_to_cache(u, cached_report(opts))
    {:ok, json, :hit} = Datastore.get_from_cache(u, 28)
    Poison.decode!(json)
  end

  defp results(report), do: report["data"]["results"]

  describe "a repository that has gone quiet since it was analysed" do
    test "crosses low -> medium rather than being served as low" do
      report = put_and_read(stored_weeks: 25, stored_risk: "low", last_commit_weeks_ago: 30)

      assert results(report)["commit_currency_weeks"] == 30
      assert results(report)["commit_currency_risk"] == "medium"
    end

    test "crosses medium -> high rather than being served as medium" do
      report = put_and_read(stored_weeks: 50, stored_risk: "medium", last_commit_weeks_ago: 60)

      assert results(report)["commit_currency_weeks"] == 60
      assert results(report)["commit_currency_risk"] == "high"
    end

    test "crosses high -> critical rather than being served as high" do
      report = put_and_read(stored_weeks: 100, stored_risk: "high", last_commit_weeks_ago: 120)

      assert results(report)["commit_currency_weeks"] == 120
      assert results(report)["commit_currency_risk"] == "critical"
    end

    test "the top-level risk follows the metric up" do
      report = put_and_read(stored_weeks: 25, stored_risk: "low", last_commit_weeks_ago: 120)

      assert report["data"]["risk"] == "critical",
             "the repository's own verdict still reads as it did at analysis time"
    end
  end

  describe "the recomputation does not invent risk" do
    test "a repository still inside the window keeps its low verdict" do
      report = put_and_read(stored_weeks: 2, stored_risk: "low", last_commit_weeks_ago: 4)

      assert results(report)["commit_currency_weeks"] == 4
      assert results(report)["commit_currency_risk"] == "low"
      assert report["data"]["risk"] == "low"
    end

    test "another metric's higher risk is not lowered by a fresher currency" do
      # The rollup is a maximum. Recomputing currency downward must not drag
      # the repository's verdict down with it.
      report =
        put_and_read(
          stored_weeks: 120,
          stored_risk: "critical",
          stored_toplevel: "critical",
          contributor_risk: "critical",
          last_commit_weeks_ago: 1
        )

      assert results(report)["commit_currency_risk"] == "low"
      assert report["data"]["risk"] == "critical"
    end
  end

  describe "a report with no commit date to recompute from" do
    # Entries cached before `data.git` existed. A missing input must not become
    # zero weeks and a "low" verdict -- that is the same bug wearing a hat.
    test "is left exactly as it was stored" do
      report = put_and_read(stored_weeks: 80, stored_risk: "critical", git: %{})

      assert results(report)["commit_currency_weeks"] == 80
      assert results(report)["commit_currency_risk"] == "critical"
      assert report["data"]["risk"] == "critical"
    end

    test "an unparseable date is left alone rather than crashing the read" do
      report =
        put_and_read(
          stored_weeks: 80,
          stored_risk: "critical",
          git: %{"last_commit_date" => "not-a-date"}
        )

      assert results(report)["commit_currency_weeks"] == 80
      assert results(report)["commit_currency_risk"] == "critical"
    end
  end

  describe "the path with no age limit at all" do
    # `cache_mode=stale` and `full_report/2` read through here, where an entry
    # can be arbitrarily old. It is the worse offender, not the lesser one.
    test "recomputes too" do
      u = url()

      {:ok, _} =
        Datastore.write_to_cache(
          u,
          cached_report(stored_weeks: 25, stored_risk: "low", last_commit_weeks_ago: 120)
        )

      {:ok, json, :stale} = Datastore.get_from_cache_any_age(u)
      report = Poison.decode!(json)

      assert results(report)["commit_currency_weeks"] == 120
      assert results(report)["commit_currency_risk"] == "critical"
      assert report["data"]["risk"] == "critical"
    end
  end
end
