# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.DatastoreTest do
  use ExUnit.Case, async: false

  setup_all do
    datetime_plus_30 = DateTime.utc_now() |> DateTime.add(-(86400 * 10)) |> DateTime.to_iso8601()

    report = %{
      data: %{
        config: %{
          critical_contributor_level: 2,
          critical_currency_level: 104,
          critical_functional_contributors_level: 2,
          critical_large_commit_level: 0.3,
          high_contributor_level: 3,
          high_currency_level: 52,
          high_functional_contributors_level: 3,
          high_large_commit_level: 0.15,
          medium_contributor_level: 5,
          medium_currency_level: 26,
          medium_functional_contributors_level: 5,
          medium_large_commit_level: 0.05
        },
        repo: "https://github.com/kitplummer/xmpp4rails",
        results: %{
          commit_currency_risk: "critical",
          commit_currency_weeks: 577,
          contributor_count: 1,
          contributor_risk: "critical",
          functional_contributor_names: ["Kit Plummer"],
          functional_contributors: 1,
          functional_contributors_risk: "critical",
          large_recent_commit_risk: "low",
          recent_commit_size_in_percent_of_codebase: 0.003683241252302026,
          top10_contributors: [%{"Kit Plummer" => 7}]
        },
        risk: "critical"
      },
      header: %{
        duration: 1,
        end_time: datetime_plus_30,
        library_version: "",
        source_client: "iex",
        start_time: "2020-02-05T02:46:51.375149Z",
        uuid: "c3996b38-47c1-11ea-97ea-88e9fe666193"
      }
    }

    [report: report]
  end

  test "it writes event", %{report: report} do
    case Redix.command(:redix, ["GET", "event:id"]) do
      {:ok, nil} ->
        {:ok, id} = LowendinsightGet.Datastore.write_event(report)
        assert 1 == id

      {:ok, curr_id} ->
        {:ok, id} = LowendinsightGet.Datastore.write_event(report)
        assert String.to_integer(curr_id) + 1 == id
    end
  end

  test "it stores and gets job" do
    uuid = UUID.uuid1()
    {:ok, res} = LowendinsightGet.Datastore.write_job(uuid, %{:test => "test"})
    assert res == "OK"
    Getter.there_yet?(false, uuid)
    {:ok, val} = Redix.command(:redix, ["GET", uuid])
    assert val == "{\"test\":\"test\"}"
    {:ok, val} = LowendinsightGet.Datastore.get_job(uuid)
    assert val == "{\"test\":\"test\"}"
  end

  test "it handles get of invalid job" do
    {:error, reason} = LowendinsightGet.Datastore.get_job("blah")
    assert reason == "job not found"
  end

  test "it handles the overwrite of a job value" do
    uuid = UUID.uuid1()
    {:ok, _res} = LowendinsightGet.Datastore.write_job(uuid, %{:test => "will_get_overwritten"})
    Getter.there_yet?(false, uuid)
    {:ok, val} = LowendinsightGet.Datastore.get_job(uuid)
    assert val == "{\"test\":\"will_get_overwritten\"}"
    {:ok, _res} = LowendinsightGet.Datastore.write_job(uuid, %{:test => "overwritten"})
    Getter.there_yet?(false, uuid)
    {:ok, val} = LowendinsightGet.Datastore.get_job(uuid)
    assert val == "{\"test\":\"overwritten\"}"
  end

  test "it does the age math correctly", %{report: report} do
    repo = elem(elem(Poison.encode(report), 1) |> Poison.decode(), 1)
    assert false == LowendinsightGet.Datastore.too_old?(repo, 30)
    datetime_plus_30 = DateTime.utc_now() |> DateTime.add(-(86400 * 30)) |> DateTime.to_iso8601()
    repo = %{"header" => %{"end_time" => datetime_plus_30}}
    assert false == LowendinsightGet.Datastore.too_old?(repo, 30)
    datetime_plus_31 = DateTime.utc_now() |> DateTime.add(-(86400 * 31)) |> DateTime.to_iso8601()
    repo = %{"header" => %{"end_time" => datetime_plus_31}}
    assert true == LowendinsightGet.Datastore.too_old?(repo, 30)
  end

  test "cache_key generates correct format" do
    assert "github:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://github.com/org/repo")

    assert "gitlab:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://gitlab.com/org/repo")

    assert "github:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://github.com/org/repo.git")
  end

  test "cache_key handles trailing slashes" do
    assert "github:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://github.com/org/repo/")
  end

  test "cache_key handles .git suffix with trailing slash" do
    assert "github:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://github.com/org/repo.git")
  end

  test "cache_key strips known TLD suffixes" do
    assert "bitbucket:team/project:latest" ==
             LowendinsightGet.Datastore.cache_key("https://bitbucket.org/team/project")

    assert "sourcehut:user/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("https://sourcehut.io/user/repo")
  end

  test "cache_key handles HTTP scheme" do
    assert "github:org/repo:latest" ==
             LowendinsightGet.Datastore.cache_key("http://github.com/org/repo")
  end

  test "cache_key produces same key for equivalent URLs" do
    key1 = LowendinsightGet.Datastore.cache_key("https://github.com/org/repo")
    key2 = LowendinsightGet.Datastore.cache_key("https://github.com/org/repo.git")
    key3 = LowendinsightGet.Datastore.cache_key("https://github.com/org/repo/")
    assert key1 == key2
    assert key1 == key3
  end

  test "cache_ttl_seconds returns configured value" do
    ttl = LowendinsightGet.Datastore.cache_ttl_seconds()
    assert is_integer(ttl)
    assert ttl > 0
  end

  test "in_cache? returns true for cached URL" do
    url = "http://repo.com/org/in_cache_check"

    report = %{
      data: %{repo: url},
      header: %{
        end_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        start_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        uuid: "test-in-cache"
      }
    }

    LowendinsightGet.Datastore.write_to_cache(url, report)
    assert LowendinsightGet.Datastore.in_cache?(url) == true
  end

  test "in_cache? returns false for uncached URL" do
    assert LowendinsightGet.Datastore.in_cache?(
             "http://repo.com/org/never_cached_#{System.unique_integer([:positive])}"
           ) == false
  end

  test "get_from_cache returns :miss for never-cached URL" do
    url = "http://repo.com/org/never_existed_#{System.unique_integer([:positive])}"

    assert {:error, "report not found", :miss} ==
             LowendinsightGet.Datastore.get_from_cache(url, 30)
  end

  test "get_from_cache returns :hit for fresh entry" do
    url = "http://repo.com/org/fresh_entry"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    report = %{
      data: %{repo: url},
      header: %{
        end_time: now,
        start_time: now,
        uuid: "fresh-uuid"
      }
    }

    LowendinsightGet.Datastore.write_to_cache(url, report)
    assert {:ok, _, :hit} = LowendinsightGet.Datastore.get_from_cache(url, 30)
  end

  test "get_from_cache returns :stale for old entry within Redis TTL" do
    url = "http://repo.com/org/stale_entry"
    old_time = DateTime.utc_now() |> DateTime.add(-(86400 * 35)) |> DateTime.to_iso8601()

    report = %{
      data: %{repo: url},
      header: %{
        end_time: old_time,
        start_time: old_time,
        uuid: "stale-uuid"
      }
    }

    LowendinsightGet.Datastore.write_to_cache(url, report)
    # Ask for 30-day freshness, but entry is 35 days old
    assert {:error, "current report not found", :stale} ==
             LowendinsightGet.Datastore.get_from_cache(url, 30)
  end

  test "write_to_cache overwrites previous entry" do
    url = "http://repo.com/org/overwrite_cache"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    report1 = %{
      data: %{repo: url, tag: "first"},
      header: %{end_time: now, start_time: now, uuid: "v1"}
    }

    report2 = %{
      data: %{repo: url, tag: "second"},
      header: %{end_time: now, start_time: now, uuid: "v2"}
    }

    LowendinsightGet.Datastore.write_to_cache(url, report1)
    LowendinsightGet.Datastore.write_to_cache(url, report2)

    {:ok, json, :hit} = LowendinsightGet.Datastore.get_from_cache(url, 30)
    decoded = Poison.decode!(json)
    assert decoded["data"]["tag"] == "second"
  end

  test "it writes and reads successfully to cache", %{report: report} do
    assert {:ok, "OK"} ==
             LowendinsightGet.Datastore.write_to_cache("http://repo.com/org/repo", report)

    {:ok, report, :hit} =
      LowendinsightGet.Datastore.get_from_cache("http://repo.com/org/repo", 30)

    repo = Poison.decode!(report)
    assert "https://github.com/kitplummer/xmpp4rails" == repo["data"]["repo"]
  end

  test "it returns successfully with not_found when uh" do
    assert {:error, "report not found", :miss} ==
             LowendinsightGet.Datastore.get_from_cache("http://repo.com/org/not_found", 30)
  end

  test "it returns correctly when cache window has expired" do
    datetime_plus_31 = DateTime.utc_now() |> DateTime.add(-(86400 * 31)) |> DateTime.to_iso8601()
    uuid = "8b08f58a-4420-11ea-8806-88e9fe666193"

    report = %{
      data: %{repo: "http://repo.com/org/expired"},
      header: %{
        end_time: datetime_plus_31,
        start_time: "2020-01-31T11:55:14.148997Z",
        uuid: uuid
      }
    }

    assert {:ok, "OK"} ==
             LowendinsightGet.Datastore.write_to_cache("http://repo.com/org/expired", report)

    Getter.there_yet?(false, uuid)

    cache_ttl = Application.get_env(:lowendinsight_get, :cache_ttl)

    assert {:error, "current report not found", :stale} ==
             LowendinsightGet.Datastore.get_from_cache("http://repo.com/org/expired", cache_ttl)

    {:ok, report, :hit} =
      LowendinsightGet.Datastore.get_from_cache("http://repo.com/org/expired", 31)

    repo = Poison.decode!(report)
    assert "http://repo.com/org/expired" == repo["data"]["repo"]
  end

  test "redis TTL is set on cached entries" do
    report = %{
      data: %{repo: "http://repo.com/org/ttl_test"},
      header: %{
        end_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        start_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        uuid: "test"
      }
    }

    LowendinsightGet.Datastore.write_to_cache("http://repo.com/org/ttl_test", report)
    key = LowendinsightGet.Datastore.cache_key("http://repo.com/org/ttl_test")
    {:ok, ttl} = Redix.command(:redix, ["TTL", key])
    assert ttl > 0
  end
end
