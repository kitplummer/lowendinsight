# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchAnalyzerTest do
  use ExUnit.Case, async: false

  setup do
    Lei.BatchCache.init()
    Lei.BatchCache.clear()
    :ok
  end

  test "returns cached results for known dependencies" do
    # Pre-populate cache
    Lei.BatchCache.put("npm", "express", "4.18.2", %{
      "risk" => "low",
      "package" => "express",
      "version" => "4.18.2"
    })

    Lei.BatchCache.put("npm", "lodash", "4.17.21", %{
      "risk" => "medium",
      "package" => "lodash",
      "version" => "4.17.21"
    })

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result["summary"]["total"] == 2
    assert result["summary"]["cached"] == 2
    assert result["summary"]["pending"] == 0
    assert length(result["results"]) == 2
    assert result["pending_jobs"] == []
    assert is_binary(result["analyzed_at"])
    assert is_integer(result["duration_ms"])
  end

  test "returns pending jobs for cache misses" do
    deps = [
      %{"ecosystem" => "npm", "package" => "nonexistent-pkg", "version" => "1.0.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result["summary"]["total"] == 1
    assert result["summary"]["cached"] == 0
    assert result["summary"]["pending"] == 1
    assert length(result["pending_jobs"]) == 1
    assert hd(result["pending_jobs"]) =~ "job-"
  end

  test "handles mix of cached and uncached dependencies" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{
      "risk" => "low",
      "package" => "express",
      "version" => "4.18.2"
    })

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "unknown-pkg", "version" => "0.1.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result["summary"]["total"] == 2
    assert result["summary"]["cached"] == 1
    assert result["summary"]["pending"] == 1
    assert length(result["results"]) == 1
    assert length(result["pending_jobs"]) == 1
  end

  test "includes risk breakdown in summary" do
    Lei.BatchCache.put("npm", "safe-pkg", "1.0.0", %{"risk" => "low"})
    Lei.BatchCache.put("npm", "risky-pkg", "1.0.0", %{"risk" => "high"})

    deps = [
      %{"ecosystem" => "npm", "package" => "safe-pkg", "version" => "1.0.0"},
      %{"ecosystem" => "npm", "package" => "risky-pkg", "version" => "1.0.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result["summary"]["risk_breakdown"]["low"] == 1
    assert result["summary"]["risk_breakdown"]["high"] == 1
  end

  test "handles empty dependencies gracefully with direct call" do
    result = Lei.BatchAnalyzer.analyze([])

    assert result["summary"]["total"] == 0
    assert result["summary"]["cached"] == 0
    assert result["summary"]["pending"] == 0
    assert result["results"] == []
    assert result["pending_jobs"] == []
  end
end
