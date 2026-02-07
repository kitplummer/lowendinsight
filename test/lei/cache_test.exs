# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.CacheTest do
  use ExUnit.Case

  @sample_report %{
    header: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      uuid: "test-uuid",
      start_time: "2026-01-01T00:00:00Z",
      end_time: "2026-01-01T00:00:05Z",
      duration: 5,
      source_client: "test",
      library_version: "0.9.0"
    },
    data: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      risk: "critical",
      git: %{hash: "abc123", default_branch: "main"},
      project_types: %{"npm" => true},
      results: %{
        contributor_count: 1,
        contributor_risk: "critical",
        commit_currency_weeks: 100,
        commit_currency_risk: "critical",
        functional_contributors_risk: "critical",
        functional_contributors: 1,
        large_recent_commit_risk: "low",
        sbom_risk: "medium"
      }
    }
  }

  setup do
    # Clean up any existing ETS/DETS tables
    try do
      :ets.delete(:lei_cache)
    rescue
      ArgumentError -> :ok
    end

    try do
      :dets.close(:lei_cache_dets)
    rescue
      _ -> :ok
    end

    # Use a temp dir for test cache
    tmp = System.tmp_dir!()
    test_cache_dir = Path.join(tmp, "lei_cache_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_cache_dir)

    Application.put_env(:lowendinsight, :cache_dir, test_cache_dir)

    Lei.Cache.init()

    on_exit(fn ->
      try do
        Lei.Cache.clear()
        Lei.Cache.close()
      rescue
        _ -> :ok
      end

      try do
        :ets.delete(:lei_cache)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf!(test_cache_dir)
      Application.delete_env(:lowendinsight, :cache_dir)
    end)

    {:ok, cache_dir: test_cache_dir}
  end

  test "put and get a cache entry" do
    :ok = Lei.Cache.put("https://github.com/test/repo", @sample_report)
    {:ok, entry} = Lei.Cache.get("https://github.com/test/repo")

    assert entry.report == @sample_report
    assert entry.ecosystem == "npm"
    assert entry.cached_at > 0
    assert entry.expires_at > entry.cached_at
  end

  test "get returns error for missing key" do
    assert {:error, :not_found} = Lei.Cache.get("nonexistent")
  end

  test "expired entries are not returned" do
    :ok = Lei.Cache.put("https://github.com/test/expired", @sample_report, ttl: 0)
    Process.sleep(10)
    assert {:error, :expired} = Lei.Cache.get("https://github.com/test/expired")
  end

  test "all_valid excludes expired entries" do
    :ok = Lei.Cache.put("valid", @sample_report, ttl: 3600)
    :ok = Lei.Cache.put("expired", @sample_report, ttl: 0)
    Process.sleep(10)

    entries = Lei.Cache.all_valid()
    keys = Enum.map(entries, fn {key, _} -> key end)

    assert "valid" in keys
    refute "expired" in keys
  end

  test "count returns number of valid entries" do
    :ok = Lei.Cache.put("repo1", @sample_report)
    :ok = Lei.Cache.put("repo2", @sample_report)

    assert Lei.Cache.count() == 2
  end

  test "stats returns ecosystem breakdown" do
    :ok = Lei.Cache.put("npm_repo", @sample_report)

    pypi_report = put_in(@sample_report, [:data, :project_types], %{"pip" => true})
    :ok = Lei.Cache.put("pypi_repo", pypi_report)

    stats = Lei.Cache.stats()
    assert stats.count == 2
    assert stats.ecosystems["npm"] == 1
    assert stats.ecosystems["pypi"] == 1
    assert stats.oldest_entry != nil
  end

  test "clear removes all entries" do
    :ok = Lei.Cache.put("repo1", @sample_report)
    :ok = Lei.Cache.clear()

    assert Lei.Cache.count() == 0
  end

  test "detects hex ecosystem" do
    report = put_in(@sample_report, [:data, :project_types], %{"mix" => true})
    :ok = Lei.Cache.put("hex_repo", report)
    {:ok, entry} = Lei.Cache.get("hex_repo")
    assert entry.ecosystem == "hex"
  end

  test "detects crates ecosystem" do
    report = put_in(@sample_report, [:data, :project_types], %{"cargo" => true})
    :ok = Lei.Cache.put("cargo_repo", report)
    {:ok, entry} = Lei.Cache.get("cargo_repo")
    assert entry.ecosystem == "crates"
  end
end
