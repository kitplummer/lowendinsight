defmodule Lei.BatchAnalyzerTest do
  use ExUnit.Case, async: false

  setup do
    Lei.BatchCache.clear()
    :ok
  end

  test "analyze returns summary with empty cache (all misses)" do
    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 2
    assert result.summary.cached == 0
    assert result.summary.pending == 2
    assert result.summary.failed == 0
    assert is_binary(result.analyzed_at)
    assert is_number(result.elapsed_ms)
    assert length(result.pending_jobs) == 2
  end

  test "analyze returns cached results when cache is warm" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{
      risk: "low",
      data: %{repo: "https://github.com/expressjs/express"}
    })

    Lei.BatchCache.put("npm", "lodash", "4.17.21", %{
      risk: "medium",
      data: %{repo: "https://github.com/lodash/lodash"}
    })

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 2
    assert result.summary.cached == 2
    assert result.summary.pending == 0
    assert result.summary.failed == 0
    assert result.summary.risk_breakdown["low"] == 1
    assert result.summary.risk_breakdown["medium"] == 1
  end

  test "analyze handles mixed cache hits and misses" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 2
    assert result.summary.cached == 1
    assert result.summary.pending == 1
  end

  test "analyze performance with 50 cached deps completes under 500ms" do
    # Warm cache with 50 entries
    for i <- 1..50 do
      Lei.BatchCache.put("npm", "pkg-#{i}", "1.0.0", %{risk: "low"})
    end

    deps =
      for i <- 1..50 do
        %{"ecosystem" => "npm", "package" => "pkg-#{i}", "version" => "1.0.0"}
      end

    start = System.monotonic_time(:millisecond)
    result = Lei.BatchAnalyzer.analyze(deps)
    elapsed = System.monotonic_time(:millisecond) - start

    assert result.summary.cached == 50
    assert elapsed < 500, "Expected <500ms, got #{elapsed}ms"
  end

  test "analyze handles crates ecosystem with empty cache" do
    deps = [
      %{"ecosystem" => "crates", "package" => "serde", "version" => "1.0.188"},
      %{"ecosystem" => "crates", "package" => "tokio", "version" => "1.32.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 2
    assert result.summary.cached == 0
    assert result.summary.pending == 2
    assert length(result.pending_jobs) == 2
  end

  test "analyze returns cached crates results" do
    Lei.BatchCache.put("crates", "serde", "1.0.188", %{
      risk: "low",
      data: %{repo: "https://github.com/serde-rs/serde"}
    })

    deps = [
      %{"ecosystem" => "crates", "package" => "serde", "version" => "1.0.188"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 1
    assert result.summary.cached == 1
    assert result.summary.pending == 0
    assert result.summary.risk_breakdown["low"] == 1
  end

  test "analyze handles mixed ecosystems (npm and crates)" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})
    Lei.BatchCache.put("crates", "serde", "1.0.188", %{risk: "medium"})

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "crates", "package" => "serde", "version" => "1.0.188"},
      %{"ecosystem" => "crates", "package" => "tokio", "version" => "1.32.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.total == 3
    assert result.summary.cached == 2
    assert result.summary.pending == 1
  end

  test "analyze with empty dependency list" do
    result = Lei.BatchAnalyzer.analyze([])

    assert result.summary.total == 0
    assert result.summary.cached == 0
    assert result.summary.pending == 0
    assert result.summary.failed == 0
    assert result.results == []
  end

  test "risk extraction handles various report formats" do
    # Test with :risk key
    Lei.BatchCache.put("npm", "pkg-atom-risk", "1.0.0", %{risk: "high"})

    deps = [%{"ecosystem" => "npm", "package" => "pkg-atom-risk", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "high"
  end

  test "risk extraction handles string key format" do
    Lei.BatchCache.put("npm", "pkg-str-risk", "1.0.0", %{"risk" => "medium"})

    deps = [%{"ecosystem" => "npm", "package" => "pkg-str-risk", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "medium"
  end

  test "risk extraction handles nested data format" do
    Lei.BatchCache.put("npm", "pkg-nested", "1.0.0", %{data: %{risk: "critical"}})

    deps = [%{"ecosystem" => "npm", "package" => "pkg-nested", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "critical"
  end

  test "risk extraction handles nested string data format" do
    Lei.BatchCache.put("npm", "pkg-nested-str", "1.0.0", %{"data" => %{"risk" => "low"}})

    deps = [%{"ecosystem" => "npm", "package" => "pkg-nested-str", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "low"
  end

  test "risk extraction returns unknown for unrecognized format" do
    Lei.BatchCache.put("npm", "pkg-no-risk", "1.0.0", %{something_else: "value"})

    deps = [%{"ecosystem" => "npm", "package" => "pkg-no-risk", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "unknown"
  end

  test "risk extraction returns unknown for non-map analysis" do
    # This triggers the extract_risk(_) catch-all clause
    Lei.BatchCache.put("npm", "pkg-non-map", "1.0.0", "just a string")

    deps = [%{"ecosystem" => "npm", "package" => "pkg-non-map", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    cached_result = Enum.find(result.results, &(&1.status == "cached"))
    assert cached_result.risk == "unknown"
  end

  test "risk breakdown counts risks correctly" do
    Lei.BatchCache.put("npm", "low1", "1.0.0", %{risk: "low"})
    Lei.BatchCache.put("npm", "low2", "1.0.0", %{risk: "low"})
    Lei.BatchCache.put("npm", "high1", "1.0.0", %{risk: "high"})
    Lei.BatchCache.put("npm", "critical1", "1.0.0", %{risk: "critical"})

    deps = [
      %{"ecosystem" => "npm", "package" => "low1", "version" => "1.0.0"},
      %{"ecosystem" => "npm", "package" => "low2", "version" => "1.0.0"},
      %{"ecosystem" => "npm", "package" => "high1", "version" => "1.0.0"},
      %{"ecosystem" => "npm", "package" => "critical1", "version" => "1.0.0"}
    ]

    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.risk_breakdown["low"] == 2
    assert result.summary.risk_breakdown["high"] == 1
    assert result.summary.risk_breakdown["critical"] == 1
    assert result.summary.risk_breakdown["medium"] == 0
  end

  test "risk breakdown handles non-standard risk category" do
    Lei.BatchCache.put("npm", "exotic-risk", "1.0.0", %{risk: "exotic"})

    deps = [%{"ecosystem" => "npm", "package" => "exotic-risk", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    assert result.summary.risk_breakdown["exotic"] == 1
    assert result.summary.risk_breakdown["low"] == 0
  end

  test "pending results include job_id" do
    deps = [%{"ecosystem" => "npm", "package" => "new-pkg", "version" => "1.0.0"}]
    result = Lei.BatchAnalyzer.analyze(deps)

    pending = Enum.find(result.results, &(&1.status == "pending"))
    assert pending != nil
    assert pending.job_id != nil
    assert String.starts_with?(pending.job_id, "job-")
  end
end
