# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.GithubTrendingTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts LowendinsightGet.Endpoint.init([])
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJKb2tlbiIsImV4cCI6MTY3MDQzNTQ1MSwiaWF0IjoxNjcwNDI4MjUxLCJpc3MiOiJKb2tlbiIsImp0aSI6IjJzbjhyOThiczNiZzNwZWwwZzAwMDA3MiIsIm5iZiI6MTY3MDQyODI1MX0.kQgqr-7lmQtlVeq96hmIIYHEniJq638NQ10VW26kT9k"
  @headers [{"authorization", "Bearer #{@token}"}]

  setup do
    on_exit(fn ->
      Task.Supervisor.children(LowendinsightGet.AnalysisSupervisor)
      |> Enum.map(fn child ->
        Task.Supervisor.terminate_child(LowendinsightGet.AnalysisSupervisor, child)
      end)
    end)
  end

  # -- API contract tests: catch upstream changes --

  describe "OSS Insight API contract" do
    @tag :network
    @tag timeout: 60_000
    test "returns repos for elixir with expected structure" do
      {:ok, repos} = LowendinsightGet.GithubTrending.fetch_from_ossinsight("elixir")
      assert is_list(repos)
      assert length(repos) > 0

      Enum.each(repos, fn repo ->
        assert is_binary(repo["url"]), "each repo must have a string url"
        assert String.starts_with?(repo["url"], "https://github.com/")
        # URL must have owner/repo format
        path = String.replace_prefix(repo["url"], "https://github.com/", "")
        assert String.contains?(path, "/"), "url must contain owner/repo: #{repo["url"]}"
      end)
    end

    @tag :network
    @tag timeout: 60_000
    test "returns repos for multiple languages" do
      for lang <- ["python", "rust", "go"] do
        result = LowendinsightGet.GithubTrending.fetch_from_ossinsight(lang)
        assert {:ok, repos} = result, "OSS Insight failed for #{lang}: #{inspect(result)}"
        assert length(repos) > 0, "OSS Insight returned 0 repos for #{lang}"
      end
    end

    @tag :network
    @tag timeout: 60_000
    test "handles special language names (c++, c#, objective-c)" do
      # These need capitalize_language to map correctly
      for lang <- ["c++", "javascript", "typescript"] do
        result = LowendinsightGet.GithubTrending.fetch_from_ossinsight(lang)
        assert {:ok, repos} = result, "OSS Insight failed for #{lang}: #{inspect(result)}"
        assert length(repos) > 0, "OSS Insight returned 0 repos for #{lang}"
      end
    end
  end

  describe "GitHub Search API contract" do
    @tag :network
    @tag timeout: 60_000
    test "returns repos for elixir with expected structure" do
      {:ok, repos} = LowendinsightGet.GithubTrending.fetch_from_github_search("elixir")
      assert is_list(repos)
      assert length(repos) > 0

      Enum.each(repos, fn repo ->
        assert is_binary(repo["url"]), "each repo must have a string url"
        assert String.starts_with?(repo["url"], "https://github.com/")
      end)
    end

    @tag :network
    @tag timeout: 60_000
    test "returns repos for multiple languages" do
      for lang <- ["python", "rust", "go"] do
        result = LowendinsightGet.GithubTrending.fetch_from_github_search(lang)
        assert {:ok, repos} = result, "GitHub Search failed for #{lang}: #{inspect(result)}"
        assert length(repos) > 0, "GitHub Search returned 0 repos for #{lang}"
      end
    end
  end

  describe "fetch_trending_list/1 (layered fallback)" do
    @tag :network
    @tag timeout: 60_000
    test "returns repos regardless of which source responds" do
      {:ok, list} = LowendinsightGet.GithubTrending.fetch_trending_list("elixir")
      assert is_list(list)
      assert length(list) > 0
      assert Enum.all?(list, fn repo -> is_binary(repo["url"]) end)

      assert Enum.all?(list, fn repo ->
               String.starts_with?(repo["url"], "https://github.com/")
             end)
    end
  end

  # -- capitalize_language --

  describe "capitalize_language/1" do
    test "maps lowercase language names to API display names" do
      assert LowendinsightGet.GithubTrending.capitalize_language("c++") == "C++"
      assert LowendinsightGet.GithubTrending.capitalize_language("c#") == "C#"
      assert LowendinsightGet.GithubTrending.capitalize_language("objective-c") == "Objective-C"
      assert LowendinsightGet.GithubTrending.capitalize_language("javascript") == "JavaScript"
      assert LowendinsightGet.GithubTrending.capitalize_language("typescript") == "TypeScript"
      assert LowendinsightGet.GithubTrending.capitalize_language("elixir") == "Elixir"
      assert LowendinsightGet.GithubTrending.capitalize_language("python") == "Python"
      assert LowendinsightGet.GithubTrending.capitalize_language("rust") == "Rust"
    end
  end

  # -- Full pipeline: analyze → Redis → report --

  describe "end-to-end refresh (network)" do
    @tag :network
    @tag timeout: 900_000
    test "refresh/1 publishes a complete report, and the page renders its rows" do
      language = "dart"

      Redix.command(:redix, [
        "DEL",
        "gh_trending_#{language}_uuid",
        "gh_trending_#{language}_completed_at"
      ])

      assert {:ok, _uuid} = LowendinsightGet.GithubTrending.refresh(language)

      # Synchronous: by the time refresh/1 returns, the report is complete.
      report = LowendinsightGet.GithubTrending.get_current_gh_trending_report(language)
      assert report["report"]["uuid"] || report["uuid"]
      assert report["state"] == "complete"
      assert [_ | _] = report["report"]["repos"]
      assert LowendinsightGet.GithubTrending.completed_at(language)

      conn = conn(:get, "/gh_trending/#{language}") |> LowendinsightGet.Endpoint.call(@opts)
      assert conn.status == 200
      # Rows, counted the way the canary counts them. (The page's "Report ID"
      # is the report's inner uuid, not the job's.)
      rows = Regex.scan(~r/var project = "https?:\/\//, conn.resp_body) |> length()
      assert rows == length(report["report"]["repos"])
      assert rows > 0
    end
  end

  # -- Endpoint integration --

  describe "POST /v1/gh_trending/process" do
    @tag :network
    @tag timeout: 60_000
    test "triggers processing and returns 200" do
      conn = conn(:post, "/v1/gh_trending/process")
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      assert conn.resp_body =~ "Processing"
    end
  end

  # -- get_current_gh_trending_report edge cases --

  describe "get_current_gh_trending_report/1" do
    test "returns empty report when no UUID exists in Redis" do
      Redix.command(:redix, ["DEL", "gh_trending_nonexistent_uuid"])
      report = LowendinsightGet.GithubTrending.get_current_gh_trending_report("nonexistent")

      assert is_map(report)
      assert report["report"]["repos"] == []
    end

    test "returns empty report when UUID exists but job data expired" do
      language = "stale_test_lang"
      fake_uuid = UUID.uuid1()

      # Set UUID but don't set corresponding job data
      Redix.command(:redix, ["SET", "gh_trending_#{language}_uuid", fake_uuid])

      report = LowendinsightGet.GithubTrending.get_current_gh_trending_report(language)

      assert is_map(report)
      assert report["report"]["repos"] == []
      assert report["report"]["uuid"] == fake_uuid

      # Cleanup
      Redix.command(:redix, ["DEL", "gh_trending_#{language}_uuid"])
    end
  end

  # -- Existing unit tests --

  test "repositories at or over the size limit are not analysed" do
    alias LowendinsightGet.GithubTrending
    assert GithubTrending.keep_repo?(999_999, true)
    refute GithubTrending.keep_repo?(1_000_000, true)
    # Size unknown -- the API could not describe it -- is not analysed.
    refute GithubTrending.keep_repo?(nil, true)
    # With the size check off, everything is.
    assert GithubTrending.keep_repo?(5_000_000, false)
    assert GithubTrending.keep_repo?(nil, false)
  end

  test "gets wait time" do
    wait_time = Application.fetch_env!(:lowendinsight_get, :wait_time)
    assert wait_time == LowendinsightGet.GithubTrending.get_wait_time()
  end
end
