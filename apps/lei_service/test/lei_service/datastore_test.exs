# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LeiService.DatastoreTest do
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
        {:ok, id} = LeiService.Datastore.write_event(report)
        assert 1 == id

      {:ok, curr_id} ->
        {:ok, id} = LeiService.Datastore.write_event(report)
        assert String.to_integer(curr_id) + 1 == id
    end
  end

  test "it stores and gets job" do
    uuid = UUID.uuid1()
    {:ok, res} = LeiService.Datastore.write_job(uuid, %{:test => "test"})
    assert res == "OK"
    Getter.there_yet?(false, uuid)
    {:ok, val} = Redix.command(:redix, ["GET", uuid])
    assert val == "{\"test\":\"test\"}"
    {:ok, val} = LeiService.Datastore.get_job(uuid)
    assert val == "{\"test\":\"test\"}"
  end

  test "it handles get of invalid job" do
    {:error, reason} = LeiService.Datastore.get_job("blah")
    assert reason == "job not found"
  end

  test "it handles the overwrite of a job value" do
    uuid = UUID.uuid1()
    {:ok, _res} = LeiService.Datastore.write_job(uuid, %{:test => "will_get_overwritten"})
    Getter.there_yet?(false, uuid)
    {:ok, val} = LeiService.Datastore.get_job(uuid)
    assert val == "{\"test\":\"will_get_overwritten\"}"
    {:ok, _res} = LeiService.Datastore.write_job(uuid, %{:test => "overwritten"})
    Getter.there_yet?(false, uuid)
    {:ok, val} = LeiService.Datastore.get_job(uuid)
    assert val == "{\"test\":\"overwritten\"}"
  end

  test "it does the age math correctly", %{report: report} do
    repo = elem(elem(Poison.encode(report), 1) |> Poison.decode(), 1)
    assert false == LeiService.Datastore.too_old?(repo, 30)
    datetime_plus_30 = DateTime.utc_now() |> DateTime.add(-(86400 * 30)) |> DateTime.to_iso8601()
    repo = %{"header" => %{"end_time" => datetime_plus_30}}
    assert false == LeiService.Datastore.too_old?(repo, 30)
    datetime_plus_31 = DateTime.utc_now() |> DateTime.add(-(86400 * 31)) |> DateTime.to_iso8601()
    repo = %{"header" => %{"end_time" => datetime_plus_31}}
    assert true == LeiService.Datastore.too_old?(repo, 30)
  end

  test "cache_key generates correct format" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/org/repo")

    assert "gitlab:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://gitlab.com/org/repo")

    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/org/repo.git")
  end

  test "cache_key handles trailing slashes" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/org/repo/")
  end

  test "cache_key handles .git suffix with trailing slash" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/org/repo.git")
  end

  # Measured on 2026-09-25: analysing this repository as kitplummer/lowendinsight
  # and as KitPlummer/lowendinsight produced two cache keys, two clones and two
  # analyses of commit 5938718 -- one answer, billed twice, stored twice. GitHub
  # treats those as one repository; cache_key/1 did not.
  test "cache_key is case-insensitive where the host is" do
    for host <- ~w(github.com gitlab.com bitbucket.org) do
      canonical = LeiService.Datastore.cache_key("https://#{host}/org/repo")

      assert canonical == LeiService.Datastore.cache_key("https://#{host}/Org/Repo"),
             "#{host}: Org/Repo is a second entry for the same repository"

      assert canonical == LeiService.Datastore.cache_key("https://#{host}/ORG/REPO")

      assert canonical ==
               LeiService.Datastore.cache_key("https://#{String.upcase(host)}/org/repo"),
             "#{host}: the host is case-insensitive per DNS and must normalise"
    end
  end

  # The other half, and the more important one. Downcasing the path everywhere
  # would merge two genuinely distinct repositories on a case-sensitive host into
  # one entry -- serving the wrong report for a repository nobody asked about.
  # A duplicate costs money; a collision answers incorrectly.
  test "cache_key preserves path case on hosts that are case-sensitive" do
    refute LeiService.Datastore.cache_key("https://git.example.com/org/Repo") ==
             LeiService.Datastore.cache_key("https://git.example.com/org/repo"),
           "an unknown host's paths were folded together, which can serve the wrong report"

    # The host half still normalises: DNS is case-insensitive regardless of host.
    assert LeiService.Datastore.cache_key("https://GIT.EXAMPLE.COM/org/Repo") ==
             LeiService.Datastore.cache_key("https://git.example.com/org/Repo")
  end

  # The canonical form has to be the one already in the cache, or every existing
  # entry is orphaned and the next request for it is billed as a cache miss.
  test "the canonical form is the lowercase one already in use" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/Org/Repo")
  end

  # Stripping .com/.org/.io from any host made distinct hosts share a key, so a
  # cache hit returned a different host's report for the same path. Worse than a
  # duplicate: a duplicate wastes a clone, this answers incorrectly.
  test "hosts differing only by TLD do not share a cache key" do
    com = LeiService.Datastore.cache_key("https://git.example.com/org/repo")
    org = LeiService.Datastore.cache_key("https://git.example.org/org/repo")
    io = LeiService.Datastore.cache_key("https://git.example.io/org/repo")

    assert length(Enum.uniq([com, org, io])) == 3,
           "git.example.{com,org,io} share a cache key and would serve each other's reports"

    refute LeiService.Datastore.cache_key("https://gitlab.com/o/r") ==
             LeiService.Datastore.cache_key("https://gitlab.io/o/r"),
           "gitlab.com and gitlab.io share a cache key"
  end

  # The reason the short names survive at all. Every key that changes shape
  # orphans a cached entry, and the next request for it is billed as a cache
  # miss -- so the hosts that hold the cache keep exactly the keys they had.
  test "the hosts that dominate the cache keep their existing keys" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://github.com/org/repo")

    assert "gitlab:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://gitlab.com/org/repo")

    assert "bitbucket:team/project:latest" ==
             LeiService.Datastore.cache_key("https://bitbucket.org/team/project")
  end

  test "an unknown host keys on its full name" do
    assert "sourcehut.io:user/repo:latest" ==
             LeiService.Datastore.cache_key("https://sourcehut.io/user/repo")

    assert "git.example.com:org/repo:latest" ==
             LeiService.Datastore.cache_key("https://git.example.com/org/repo")
  end

  test "cache_key handles HTTP scheme" do
    assert "github:org/repo:latest" ==
             LeiService.Datastore.cache_key("http://github.com/org/repo")
  end

  test "cache_key produces same key for equivalent URLs" do
    key1 = LeiService.Datastore.cache_key("https://github.com/org/repo")
    key2 = LeiService.Datastore.cache_key("https://github.com/org/repo.git")
    key3 = LeiService.Datastore.cache_key("https://github.com/org/repo/")
    assert key1 == key2
    assert key1 == key3
  end

  test "cache_ttl_seconds returns configured value" do
    ttl = LeiService.Datastore.cache_ttl_seconds()
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

    LeiService.Datastore.write_to_cache(url, report)
    assert LeiService.Datastore.in_cache?(url) == true
  end

  test "in_cache? returns false for uncached URL" do
    assert LeiService.Datastore.in_cache?(
             "http://repo.com/org/never_cached_#{System.unique_integer([:positive])}"
           ) == false
  end

  test "get_from_cache returns :miss for never-cached URL" do
    url = "http://repo.com/org/never_existed_#{System.unique_integer([:positive])}"

    assert {:error, "report not found", :miss} ==
             LeiService.Datastore.get_from_cache(url, 30)
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

    LeiService.Datastore.write_to_cache(url, report)
    assert {:ok, _, :hit} = LeiService.Datastore.get_from_cache(url, 30)
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

    LeiService.Datastore.write_to_cache(url, report)
    # Ask for 30-day freshness, but entry is 35 days old
    assert {:error, "current report not found", :stale} ==
             LeiService.Datastore.get_from_cache(url, 30)
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

    LeiService.Datastore.write_to_cache(url, report1)
    LeiService.Datastore.write_to_cache(url, report2)

    {:ok, json, :hit} = LeiService.Datastore.get_from_cache(url, 30)
    decoded = Poison.decode!(json)
    assert decoded["data"]["tag"] == "second"
  end

  test "it writes and reads successfully to cache", %{report: report} do
    assert {:ok, "OK"} ==
             LeiService.Datastore.write_to_cache("http://repo.com/org/repo", report)

    {:ok, report, :hit} =
      LeiService.Datastore.get_from_cache("http://repo.com/org/repo", 30)

    repo = Poison.decode!(report)
    assert "https://github.com/kitplummer/xmpp4rails" == repo["data"]["repo"]
  end

  test "it returns successfully with not_found when uh" do
    assert {:error, "report not found", :miss} ==
             LeiService.Datastore.get_from_cache("http://repo.com/org/not_found", 30)
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
             LeiService.Datastore.write_to_cache("http://repo.com/org/expired", report)

    Getter.there_yet?(false, uuid)

    cache_ttl = Application.get_env(:lei_service, :cache_ttl)

    assert {:error, "current report not found", :stale} ==
             LeiService.Datastore.get_from_cache("http://repo.com/org/expired", cache_ttl)

    {:ok, report, :hit} =
      LeiService.Datastore.get_from_cache("http://repo.com/org/expired", 31)

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

    LeiService.Datastore.write_to_cache("http://repo.com/org/ttl_test", report)
    key = LeiService.Datastore.cache_key("http://repo.com/org/ttl_test")
    {:ok, ttl} = Redix.command(:redix, ["TTL", key])
    assert ttl > 0
  end
end
