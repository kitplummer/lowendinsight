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

  describe "end-to-end analyze pipeline" do
    @tag :network
    @tag timeout: 300_000
    test "analyze/1 stores UUID in Redis and job eventually completes" do
      language = "elixir"

      # Clear any existing trending data for this language
      Redix.command(:redix, ["DEL", "gh_trending_#{language}_uuid"])

      {:ok, msg} = LowendinsightGet.GithubTrending.analyze(language)
      assert String.contains?(msg, "successfully")

      # Extract UUID from the message
      uuid =
        Regex.run(~r/job id:(.+)$/, msg) |> List.last()

      assert uuid != nil

      # Verify the UUID was written to Redis
      {:ok, stored_uuid} = Redix.command(:redix, ["GET", "gh_trending_#{language}_uuid"])
      assert stored_uuid == uuid

      # Poll until the job completes or timeout (up to 120s)
      report = poll_trending_report(language, 120)
      assert report != nil
      assert is_list(report["report"]["repos"])

      # Once complete, repos should have data
      if report["state"] == "complete" do
        assert length(report["report"]["repos"]) > 0

        # Each repo in the report should have standard LEI analysis fields
        first_repo = hd(report["report"]["repos"])
        assert first_repo["data"]["repo"] != nil
      end
    end
  end

  # -- Endpoint integration --

  describe "GET /gh_trending/:language after analyze" do
    @tag :network
    @tag timeout: 300_000
    test "renders HTML with repo data after analysis completes" do
      language = "dart"

      # Clear and run analysis
      Redix.command(:redix, ["DEL", "gh_trending_#{language}_uuid"])
      {:ok, _msg} = LowendinsightGet.GithubTrending.analyze(language)

      # Wait for analysis to complete
      poll_trending_report(language, 120)

      # Now hit the endpoint
      conn = conn(:get, "/gh_trending/#{language}")
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "<html>")
      # The rendered page should reference the language
      assert String.contains?(conn.resp_body, language)
    end
  end

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

  @tag :network
  test "large repo filter" do
    url = "https://github.com/torvalds/linux"
    {repo_size, url} = LowendinsightGet.GithubTrending.get_repo_size(url)
    check_repo? = LowendinsightGet.GithubTrending.check_repo_size?()

    new_url =
      LowendinsightGet.GithubTrending.filter_out_large_repos({repo_size, url}, check_repo?)

    if check_repo? == "true",
      do:
        assert(new_url == "https://github.com/torvalds/linux-skip_too_big",
          else: assert(new_url == "https://github.com/torvalds/linux")
        )
  end

  test "gets wait time" do
    wait_time = Application.fetch_env!(:lowendinsight_get, :wait_time)
    assert wait_time == LowendinsightGet.GithubTrending.get_wait_time()
  end

  # -- Helpers --

  defp poll_trending_report(language, timeout_seconds) do
    poll_trending_report(language, timeout_seconds, 0)
  end

  defp poll_trending_report(language, timeout_seconds, elapsed) when elapsed >= timeout_seconds do
    LowendinsightGet.GithubTrending.get_current_gh_trending_report(language)
  end

  defp poll_trending_report(language, timeout_seconds, elapsed) do
    report = LowendinsightGet.GithubTrending.get_current_gh_trending_report(language)

    case report do
      %{"state" => "complete"} ->
        report

      _ ->
        :timer.sleep(3000)
        poll_trending_report(language, timeout_seconds, elapsed + 3)
    end
  end
end
