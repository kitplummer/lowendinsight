defmodule Lei.BatchRankingTest do
  @moduledoc """
  A manifest scan is ranked, not just counted (#263).

  #262 added `risk_rank` and `metadata.ranking` through
  `AnalyzerModule.determine_risk_counts/1`, which the batch dependency path
  never calls. So the ranking existed on the URL-list path and was absent from
  the manifest path — the case where "I have four hundred criticals, what do I
  open first" is actually asked, and the one ADR-001 calls the primary use.

  Measured on a real npm tree, 54% of repositories score `critical` and none
  score `low`, so severity alone orders nothing.

  The entries that carry no analysis matter as much as the ones that do. A
  first scan is mostly `pending`, and those must not sort as though they were
  examined and found healthy.
  """
  use ExUnit.Case, async: false

  alias Lei.BatchAnalyzer

  defp dep(pkg), do: %{"ecosystem" => "hex", "package" => pkg, "version" => "1.0.0"}

  defp report(results) do
    %{"data" => %{"repo" => "https://example.com/r", "results" => results, "risk" => "critical"}}
  end

  # The real cache rather than a stub, so partition_by_cache/2 is exercised as
  # it runs. It is the library-side ETS store, so this touches nothing outside
  # the node.
  defp with_cache(entries) do
    Lei.BatchCache.clear()
    for {pkg, result} <- entries, do: :ok = Lei.BatchCache.put("hex", pkg, "1.0.0", result)
    on_exit(fn -> Lei.BatchCache.clear() end)
  end

  defp ranking(result), do: result.ranking

  describe "a scan with analyses in hand" do
    setup do
      with_cache(%{
        "worst" => report(%{"a_risk" => "critical", "b_risk" => "critical", "c_risk" => "high"}),
        "bad" => report(%{"a_risk" => "critical"}),
        "mild" => report(%{"a_risk" => "medium"})
      })

      :ok
    end

    test "is ordered worst first" do
      result =
        BatchAnalyzer.analyze([dep("mild"), dep("worst"), dep("bad")],
          schedule: fn _ -> :skip end
        )

      assert Enum.map(ranking(result), & &1.package) == ["worst", "bad", "mild"]
    end

    test "carries the profile, so the order can be explained" do
      result = BatchAnalyzer.analyze([dep("worst")], schedule: fn _ -> :skip end)

      [first] = ranking(result)

      assert first.profile["counts"]["critical"] == 2
      assert first.profile["counts"]["high"] == 1
      assert first.rank > 0
    end

    test "each result carries its own rank, not only the ranking list" do
      result = BatchAnalyzer.analyze([dep("bad")], schedule: fn _ -> :skip end)

      [entry] = result.results
      assert entry.risk_rank > 0
      assert entry.risk_profile["counts"]["critical"] == 1
    end
  end

  describe "entries with no analysis yet" do
    test "sort last, and are not given a rank of zero" do
      # Zero is what a clean repository scores. A dependency nobody has looked
      # at must not sort alongside one examined and found healthy -- on a first
      # scan that is most of the manifest.
      with_cache(%{"bad" => report(%{"a_risk" => "critical"})})

      result =
        BatchAnalyzer.analyze([dep("unknown"), dep("bad")], schedule: fn _ -> {:ok, "job-1"} end)

      assert Enum.map(ranking(result), & &1.package) == ["bad", "unknown"]

      unknown = Enum.find(ranking(result), &(&1.package == "unknown"))
      assert unknown.rank == nil, "an unexamined dependency was given a numeric rank"
      assert unknown.status == "pending"
    end

    test "are present rather than dropped" do
      # A shorter list reads as less to fix.
      with_cache(%{})

      result =
        BatchAnalyzer.analyze([dep("a"), dep("b")], schedule: fn _ -> {:ok, "job-1"} end)

      assert length(ranking(result)) == 2
    end

    test "a wholly unanalysed manifest still ranks every entry" do
      with_cache(%{})

      result =
        BatchAnalyzer.analyze([dep("a"), dep("b"), dep("c")], schedule: fn _ -> {:ok, "j"} end)

      assert length(ranking(result)) == 3
      assert Enum.all?(ranking(result), &is_nil(&1.rank))
    end
  end
end
