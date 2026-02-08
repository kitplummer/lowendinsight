# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchCacheTest do
  use ExUnit.Case, async: false

  setup do
    Lei.BatchCache.init()
    Lei.BatchCache.clear()
    :ok
  end

  test "put and get a cache entry" do
    :ok = Lei.BatchCache.put("npm", "express", "4.18.2", %{"risk" => "low"})
    {:ok, entry} = Lei.BatchCache.get("npm", "express", "4.18.2")

    assert entry.result == %{"risk" => "low"}
    assert entry.ecosystem == "npm"
  end

  test "get returns error for missing entry" do
    assert {:error, :not_found} = Lei.BatchCache.get("npm", "nonexistent", "1.0.0")
  end

  test "expired entries are not returned" do
    :ok = Lei.BatchCache.put("npm", "old-pkg", "1.0.0", %{"risk" => "low"}, ttl: -1)
    assert {:error, :expired} = Lei.BatchCache.get("npm", "old-pkg", "1.0.0")
  end

  test "lookup_batch returns hits and misses" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{"risk" => "low"})

    deps = [
      %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"},
      %{"ecosystem" => "npm", "package" => "missing", "version" => "1.0.0"}
    ]

    {hits, misses} = Lei.BatchCache.lookup_batch(deps)

    assert length(hits) == 1
    assert length(misses) == 1

    {dep, entry} = hd(hits)
    assert dep["package"] == "express"
    assert entry.result == %{"risk" => "low"}

    assert hd(misses)["package"] == "missing"
  end

  test "keys are case-insensitive" do
    Lei.BatchCache.put("NPM", "Express", "4.18.2", %{"risk" => "low"})
    {:ok, _entry} = Lei.BatchCache.get("npm", "express", "4.18.2")
  end

  test "clear removes all entries" do
    Lei.BatchCache.put("npm", "a", "1.0.0", %{"risk" => "low"})
    Lei.BatchCache.put("npm", "b", "1.0.0", %{"risk" => "low"})

    Lei.BatchCache.clear()

    assert {:error, :not_found} = Lei.BatchCache.get("npm", "a", "1.0.0")
    assert {:error, :not_found} = Lei.BatchCache.get("npm", "b", "1.0.0")
  end
end
