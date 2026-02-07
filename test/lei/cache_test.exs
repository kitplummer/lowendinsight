defmodule Lei.CacheTest do
  use ExUnit.Case, async: false

  setup do
    :ets.delete_all_objects(:lei_analysis_cache)
    :ok
  end

  test "get returns :miss for unknown keys" do
    assert Lei.Cache.get("npm", "nonexistent", "1.0.0") == :miss
  end

  test "put and get round-trips data" do
    data = %{"risk" => "low", "package" => "test"}
    Lei.Cache.put("npm", "test-pkg", "1.0.0", data)
    assert {:ok, ^data} = Lei.Cache.get("npm", "test-pkg", "1.0.0")
  end

  test "different versions are separate cache entries" do
    Lei.Cache.put("npm", "pkg", "1.0", %{"v" => "1"})
    Lei.Cache.put("npm", "pkg", "2.0", %{"v" => "2"})

    assert {:ok, %{"v" => "1"}} = Lei.Cache.get("npm", "pkg", "1.0")
    assert {:ok, %{"v" => "2"}} = Lei.Cache.get("npm", "pkg", "2.0")
  end

  test "different ecosystems are separate cache entries" do
    Lei.Cache.put("npm", "pkg", "1.0", %{"eco" => "npm"})
    Lei.Cache.put("hex", "pkg", "1.0", %{"eco" => "hex"})

    assert {:ok, %{"eco" => "npm"}} = Lei.Cache.get("npm", "pkg", "1.0")
    assert {:ok, %{"eco" => "hex"}} = Lei.Cache.get("hex", "pkg", "1.0")
  end
end
