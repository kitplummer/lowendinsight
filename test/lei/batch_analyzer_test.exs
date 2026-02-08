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
end
