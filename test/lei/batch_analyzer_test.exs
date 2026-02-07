# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchAnalyzerTest do
  use ExUnit.Case, async: false

  setup do
    :ets.delete_all_objects(:lei_batch_cache)
    :ok
  end

  describe "analyze/1" do
    test "returns cached results for previously analyzed dependencies" do
      Lei.BatchCache.put("npm", "express", "4.18.2", %{
        "ecosystem" => "npm",
        "package" => "express",
        "version" => "4.18.2",
        "risk" => "low",
        "report" => %{}
      })

      result = Lei.BatchAnalyzer.analyze([
        %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}
      ])

      assert result["summary"]["total"] == 1
      assert result["summary"]["cached"] == 1
      assert result["summary"]["pending"] == 0
      assert result["summary"]["failed"] == 0
      assert length(result["results"]) == 1
      assert hd(result["results"])["package"] == "express"
      assert result["analyzed_at"] != nil
    end

    test "enqueues Oban jobs for cache misses" do
      result = Lei.BatchAnalyzer.analyze([
        %{"ecosystem" => "npm", "package" => "nonexistent-pkg-xyz", "version" => "1.0.0"}
      ])

      assert result["summary"]["total"] == 1
      assert result["summary"]["cached"] == 0
      assert result["summary"]["pending"] == 1
      assert length(result["pending_jobs"]) == 1
      assert hd(result["pending_jobs"]) =~ ~r/^job-\d+$/
    end

    test "handles mixed cached and uncached dependencies" do
      Lei.BatchCache.put("npm", "lodash", "4.17.21", %{
        "ecosystem" => "npm",
        "package" => "lodash",
        "version" => "4.17.21",
        "risk" => "medium",
        "report" => %{}
      })

      result = Lei.BatchAnalyzer.analyze([
        %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"},
        %{"ecosystem" => "npm", "package" => "unknown-pkg-abc", "version" => "0.0.1"}
      ])

      assert result["summary"]["total"] == 2
      assert result["summary"]["cached"] == 1
      assert result["summary"]["pending"] == 1
    end

    test "computes risk breakdown from cached results" do
      Lei.BatchCache.put("npm", "a", "1.0", %{"risk" => "low"})
      Lei.BatchCache.put("npm", "b", "1.0", %{"risk" => "low"})
      Lei.BatchCache.put("npm", "c", "1.0", %{"risk" => "high"})

      result = Lei.BatchAnalyzer.analyze([
        %{"ecosystem" => "npm", "package" => "a", "version" => "1.0"},
        %{"ecosystem" => "npm", "package" => "b", "version" => "1.0"},
        %{"ecosystem" => "npm", "package" => "c", "version" => "1.0"}
      ])

      assert result["summary"]["risk_breakdown"]["low"] == 2
      assert result["summary"]["risk_breakdown"]["high"] == 1
    end

    test "defaults version to 'latest' when not specified" do
      Lei.BatchCache.put("hex", "poison", "latest", %{
        "ecosystem" => "hex",
        "package" => "poison",
        "risk" => "low"
      })

      result = Lei.BatchAnalyzer.analyze([
        %{"ecosystem" => "hex", "package" => "poison"}
      ])

      assert result["summary"]["cached"] == 1
    end
  end
end
