defmodule Lei.BatchCacheTest do
  use ExUnit.Case, async: false

  setup do
    Lei.BatchCache.clear()
    :ok
  end

  test "put and get a cached entry" do
    :ok = Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})
    {:ok, entry} = Lei.BatchCache.get("npm", "express", "4.18.2")

    assert entry.result.risk == "low"
    assert entry.ecosystem == "npm"
    assert entry.package == "express"
    assert entry.version == "4.18.2"
  end

  test "get returns not_found for missing entry" do
    assert {:error, :not_found} = Lei.BatchCache.get("npm", "missing", "1.0.0")
  end

  test "get returns expired for old entry" do
    :ok = Lei.BatchCache.put("npm", "old", "1.0.0", %{risk: "low"}, ttl: 0)
    # TTL of 0 means it expires immediately (same second)
    Process.sleep(1100)
    assert {:error, :expired} = Lei.BatchCache.get("npm", "old", "1.0.0")
  end

  test "multi_get returns results for multiple dependencies" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})
    Lei.BatchCache.put("npm", "lodash", "4.17.21", %{risk: "medium"})

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "lodash", "version" => "4.17.21"},
      %{"ecosystem" => "npm", "package" => "missing", "version" => "1.0.0"}
    ]

    results = Lei.BatchCache.multi_get(deps)

    assert {:ok, _} = results["npm:express:4.18.2"]
    assert {:ok, _} = results["npm:lodash:4.17.21"]
    assert {:error, :not_found} = results["npm:missing:1.0.0"]
  end

  test "stats returns ecosystem breakdown" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})
    Lei.BatchCache.put("npm", "lodash", "4.17.21", %{risk: "low"})
    Lei.BatchCache.put("pypi", "requests", "2.31.0", %{risk: "medium"})

    stats = Lei.BatchCache.stats()

    assert stats.count == 3
    assert stats.ecosystems["npm"] == 2
    assert stats.ecosystems["pypi"] == 1
  end

  test "clear removes all entries" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{risk: "low"})
    assert {:ok, _} = Lei.BatchCache.get("npm", "express", "4.18.2")

    Lei.BatchCache.clear()
    assert {:error, :not_found} = Lei.BatchCache.get("npm", "express", "4.18.2")
  end
end
