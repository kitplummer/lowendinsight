defmodule Lei.RiskRankingTest do
  @moduledoc """
  Ordering a report by what to look at first (#247).

  Measured across a 99-repository sample of a real npm dependency tree: 54%
  scored `critical`, 18% `high`, 27% `medium`, and **not one** scored `low`.
  At that density the verdict stops discriminating -- a customer cannot act on
  "half your tree is critical", and cannot replace half their dependencies.

  `risk_profile` already carried the distribution the verdict was collapsed
  from. This turns it into an order: criticals first, then highs, then mediums,
  so a repository with three critical metrics outranks one with a single
  critical metric though both read `critical`.
  """
  use ExUnit.Case, async: true

  alias Lei.RiskProfile

  defp profile(results), do: RiskProfile.of(results)

  describe "ranking within a single verdict" do
    test "three critical metrics outrank one" do
      many =
        profile(%{
          "functional_contributors_risk" => "critical",
          "functional_commit_currency_risk" => "critical",
          "contributor_risk" => "critical"
        })

      one = profile(%{"functional_contributors_risk" => "critical", "b" => "low"})

      assert RiskProfile.rank(many) > RiskProfile.rank(one)
    end

    test "a critical always outranks any number of highs" do
      # Base 100 rather than 10: a report can carry more than nine metrics, and
      # a carry would let three highs quietly outrank a critical.
      highs = profile(Map.new(1..40, fn i -> {"m#{i}_risk", "high"} end))
      one_critical = profile(%{"a_risk" => "critical"})

      assert RiskProfile.rank(one_critical) > RiskProfile.rank(highs)
    end

    test "highs break ties between equal criticals" do
      a = profile(%{"x_risk" => "critical", "y_risk" => "high"})
      b = profile(%{"x_risk" => "critical", "y_risk" => "medium"})

      assert RiskProfile.rank(a) > RiskProfile.rank(b)
    end

    test "a clean report ranks zero" do
      assert RiskProfile.rank(profile(%{"a_risk" => "low", "b_risk" => "low"})) == 0
    end

    test "results can be passed directly" do
      assert RiskProfile.rank(%{"a_risk" => "critical"}) ==
               RiskProfile.rank(profile(%{"a_risk" => "critical"}))
    end
  end

  describe "a multi-repository report" do
    # No :risk key: determine_toplevel_risk/1 uses Map.put_new/3, so a report
    # that already carries one keeps it. A real report has none before this
    # call, and setting a placeholder here would have tested the fixture.
    defp repo(url, results) do
      AnalyzerModule.determine_toplevel_risk(%{data: %{repo: url, results: results}})
    end

    test "is ranked worst first" do
      report = %{
        metadata: %{},
        report: %{
          repos: [
            repo("https://x/mild", %{"a_risk" => "medium"}),
            repo("https://x/worst", %{"a_risk" => "critical", "b_risk" => "critical"}),
            repo("https://x/bad", %{"a_risk" => "critical"})
          ]
        }
      }

      ranked = AnalyzerModule.determine_risk_counts(report)[:metadata][:ranking]

      assert Enum.map(ranked, & &1.repo) == [
               "https://x/worst",
               "https://x/bad",
               "https://x/mild"
             ]
    end

    test "carries the profile, so the order can be explained" do
      report = %{
        metadata: %{},
        report: %{repos: [repo("https://x/a", %{"a_risk" => "critical", "b_risk" => "high"})]}
      }

      [first] = AnalyzerModule.determine_risk_counts(report)[:metadata][:ranking]

      assert first.risk == "critical"
      assert first.profile["counts"]["critical"] == 1
      assert first.profile["elevated"] == ["a_risk", "b_risk"]
    end

    test "a repository whose shape cannot be read still appears, ranked last" do
      # Dropping it would quietly shorten the list a customer is using to
      # decide what to fix -- a shorter list reads as less to do.
      report = %{
        metadata: %{},
        report: %{
          repos: [
            %{"unexpected" => "shape"},
            repo("https://x/bad", %{"a_risk" => "critical"})
          ]
        }
      }

      ranked = AnalyzerModule.determine_risk_counts(report)[:metadata][:ranking]

      assert length(ranked) == 2, "a repository vanished from the ranking"
      assert List.first(ranked).repo == "https://x/bad"
      assert List.last(ranked).rank == -1
    end

    test "cached repos, which decode to string keys, rank alongside fresh ones" do
      fresh = repo("https://x/fresh", %{"a_risk" => "high"})

      cached = %{
        "data" => %{
          "repo" => "https://x/cached",
          "risk" => "critical",
          "risk_rank" => 10_000,
          "risk_profile" => %{"counts" => %{"critical" => 1}, "elevated" => ["a_risk"]}
        }
      }

      report = %{metadata: %{}, report: %{repos: [fresh, cached]}}
      ranked = AnalyzerModule.determine_risk_counts(report)[:metadata][:ranking]

      assert List.first(ranked).repo == "https://x/cached"
    end
  end

  describe "the per-repository key" do
    test "is set beside the verdict" do
      decided =
        AnalyzerModule.determine_toplevel_risk(%{
          data: %{results: %{"a_risk" => "critical", "b_risk" => "high"}}
        })

      assert decided[:data][:risk_rank] == 10_100
      assert decided[:data][:risk] == "critical"
    end
  end
end
