defmodule LowendinsightGet.TrendingRefreshTest do
  @moduledoc """
  The trending job completes, one language at a time, and never replaces a
  good report with a placeholder (#158).

  In production every language pointed at a report stuck "incomplete": the
  midnight job started all fourteen languages' analyses at once, asynchronously,
  the machine ran out of memory, and the kill left placeholders the page
  rendered as empty. These drive the refresh with the network steps injected,
  so no clone or API call is made.
  """
  use ExUnit.Case, async: false

  alias LowendinsightGet.{Datastore, GithubTrending}

  @languages ["zz-trend-a", "zz-trend-b", "zz-trend-c"]

  setup do
    clear = fn ->
      keys =
        Enum.flat_map(@languages, &["gh_trending_#{&1}_uuid", "gh_trending_#{&1}_completed_at"])

      Redix.command(:redix, ["DEL", "gh_trending_lock" | keys])
    end

    clear.()
    on_exit(clear)
    :ok
  end

  # The size check is on in test config; answer it without the GitHub API.
  defp small(url), do: {100, url}

  defp list_for(language) do
    {:ok, [%{"url" => "https://github.com/example/#{language}-one"}]}
  end

  # Writes a complete report for the job, as Analysis.process/3 does.
  defp completing_analysis(test_pid \\ nil) do
    fn uuid, urls, _start ->
      if test_pid, do: send(test_pid, {:analysing, uuid, self()})

      Datastore.write_job(uuid, %{
        state: "complete",
        report: %{uuid: uuid, repos: Enum.map(urls, &%{data: %{repo: &1}})},
        metadata: %{times: %{end_time: "t"}}
      })
    end
  end

  defp pointer(language) do
    {:ok, uuid} = Redix.command(:redix, ["GET", "gh_trending_#{language}_uuid"])
    uuid
  end

  describe "refresh/2" do
    test "a completed analysis is published, with when it completed" do
      assert {:ok, uuid} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: &list_for/1,
                 repo_size: &small/1,
                 analyze: completing_analysis()
               )

      assert pointer("zz-trend-a") == uuid
      assert %DateTime{} = GithubTrending.completed_at("zz-trend-a")
    end

    test "an analysis that does not complete never replaces the previous report" do
      {:ok, good} =
        GithubTrending.refresh("zz-trend-a",
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: completing_analysis()
        )

      completed = GithubTrending.completed_at("zz-trend-a")

      # Writes the placeholder an async analysis leaves behind.
      incomplete = fn uuid, _urls, _start ->
        Datastore.write_job(uuid, %{state: "incomplete", report: %{uuid: uuid, repos: []}})
      end

      assert {:error, {:incomplete, "incomplete"}} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: &list_for/1,
                 repo_size: &small/1,
                 analyze: incomplete
               )

      assert pointer("zz-trend-a") == good
      assert GithubTrending.completed_at("zz-trend-a") == completed
    end

    test "an analysis that raises or exits is a failed refresh, not a crashed job" do
      raising = fn _uuid, _urls, _start -> raise "clone failed" end
      exiting = fn _uuid, _urls, _start -> exit(:killed) end

      assert {:error, {:analysis_raised, "clone failed"}} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: &list_for/1,
                 repo_size: &small/1,
                 analyze: raising
               )

      assert {:error, {:analysis_exited, :exit, :killed}} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: &list_for/1,
                 repo_size: &small/1,
                 analyze: exiting
               )

      assert pointer("zz-trend-a") == nil
    end

    test "repositories over the size limit are dropped, not sent for analysis" do
      two = fn _ ->
        {:ok,
         [
           %{"url" => "https://github.com/example/big"},
           %{"url" => "https://github.com/example/small"}
         ]}
      end

      sizes = fn
        "https://github.com/example/big" = url -> {2_000_000, url}
        url -> {100, url}
      end

      analysed =
        fn uuid, urls, start ->
          send(self(), {:urls, urls})
          completing_analysis().(uuid, urls, start)
        end

      assert {:ok, _} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: two,
                 repo_size: sizes,
                 analyze: analysed
               )

      assert_received {:urls, ["https://github.com/example/small"]}
    end

    test "a failed trending list leaves the report alone" do
      assert {:error, :upstream_down} =
               GithubTrending.refresh("zz-trend-a",
                 fetch: fn _ -> {:error, :upstream_down} end,
                 repo_size: &small/1,
                 analyze: completing_analysis()
               )

      assert pointer("zz-trend-a") == nil
    end
  end

  describe "refresh_due/1" do
    test "languages are analysed one at a time, each finishing before the next starts" do
      {:ok, active} = Agent.start_link(fn -> {0, 0} end)

      tracking = fn uuid, urls, start ->
        Agent.update(active, fn {now, peak} -> {now + 1, max(peak, now + 1)} end)
        Process.sleep(20)
        completing_analysis().(uuid, urls, start)
        Agent.update(active, fn {now, peak} -> {now - 1, peak} end)
      end

      results =
        GithubTrending.refresh_due(
          languages: @languages,
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: tracking
        )

      assert Enum.map(results, fn {l, {status, _}} -> {l, status} end) ==
               Enum.map(@languages, &{&1, :ok})

      assert {0, 1} = Agent.get(active, & &1)
    end

    test "a language refreshed within the last day is skipped, so a restart resumes" do
      # A run that was killed after the first language.
      {:ok, _} =
        GithubTrending.refresh("zz-trend-a",
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: completing_analysis(self())
        )

      assert_received {:analysing, _, _}

      results =
        GithubTrending.refresh_due(
          languages: @languages,
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: completing_analysis(self())
        )

      assert Enum.map(results, &elem(&1, 0)) == ["zz-trend-b", "zz-trend-c"]
    end

    test "a language is due again after a day" do
      {:ok, _} =
        GithubTrending.refresh("zz-trend-a",
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: completing_analysis()
        )

      refute GithubTrending.due?("zz-trend-a")

      assert GithubTrending.due?(
               "zz-trend-a",
               DateTime.add(DateTime.utc_now(), 24 * 3600 + 1, :second)
             )
    end

    test "only one run analyses at a time" do
      Redix.command(:redix, ["SET", "gh_trending_lock", "someone-else", "PX", 60_000])

      assert {:error, :already_running} =
               GithubTrending.refresh_due(
                 languages: @languages,
                 fetch: &list_for/1,
                 repo_size: &small/1,
                 analyze: fn _, _, _ -> flunk("analysed while another run held the lock") end
               )
    end

    test "the lock is released when a run ends, even a failed one" do
      GithubTrending.refresh_due(
        languages: ["zz-trend-a"],
        fetch: fn _ -> raise "boom" end,
        repo_size: &small/1,
        analyze: completing_analysis()
      )
    rescue
      _ -> :ok
    after
      assert {:ok, nil} = Redix.command(:redix, ["GET", "gh_trending_lock"])
    end
  end

  describe "the page" do
    test "renders one row per analysed repository, in the shape the canary counts" do
      # The canary counts `var project = "<url>"` in the rendered page. Pinned
      # here against the real template, so a template change that breaks the
      # count fails a test rather than silently zeroing a check.
      {:ok, _} =
        GithubTrending.refresh("zz-trend-a",
          fetch: fn _ ->
            {:ok,
             [
               %{"url" => "https://github.com/example/one"},
               %{"url" => "https://github.com/example/two"}
             ]}
          end,
          repo_size: &small/1,
          analyze: fn uuid, urls, _start ->
            Datastore.write_job(uuid, %{
              state: "complete",
              report: %{uuid: uuid, repos: Enum.map(urls, &%{data: %{repo: &1, results: %{}}})},
              metadata: %{times: %{end_time: "2026-09-14T00:10:00Z"}}
            })
          end
        )

      conn =
        Plug.Test.conn(:get, "/gh_trending/zz-trend-a")
        |> LowendinsightGet.Endpoint.call(LowendinsightGet.Endpoint.init([]))

      assert conn.status == 200
      assert length(Regex.scan(~r/var project = "https?:\/\//, conn.resp_body)) == 2
      assert conn.resp_body =~ "2026-09-14T00:10:00Z"
    end
  end

  describe "the schedule" do
    test "runs hourly and never overlaps itself" do
      job = LowendinsightGet.Scheduler.find_job(:github_trending)

      assert job, "the trending job is not scheduled"
      assert job.task == {GithubTrending, :refresh_due, []}
      assert job.overlap == false
      assert Crontab.CronExpression.Composer.compose(job.schedule) =~ ~r/^0 \* \* \* \*/
    end

    test "is disabled until per-repository memory is bounded (#158)" do
      # Its first production run OOM-killed the service. Delete this test when
      # the job is deliberately re-enabled -- not before.
      assert LowendinsightGet.Scheduler.find_job(:github_trending).state == :inactive
    end
  end

  describe "metrics/1" do
    test "reports each language's completion and the age of its report" do
      previous = Application.get_env(:lowendinsight_get, :languages)
      Application.put_env(:lowendinsight_get, :languages, @languages)
      on_exit(fn -> Application.put_env(:lowendinsight_get, :languages, previous) end)

      {:ok, _} =
        GithubTrending.refresh("zz-trend-a",
          fetch: &list_for/1,
          repo_size: &small/1,
          analyze: completing_analysis()
        )

      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      lines = GithubTrending.metrics(later) |> Enum.join("\n")

      assert lines =~ "lei_trending_job_active 0"
      assert lines =~ ~s(lei_trending_report_completed{language="zz-trend-a"} 1)
      assert lines =~ ~s(lei_trending_report_completed{language="zz-trend-b"} 0)
      assert lines =~ ~r/lei_trending_report_age_seconds\{language="zz-trend-a"\} 3[56]\d\d/
      refute lines =~ ~s(lei_trending_report_age_seconds{language="zz-trend-b"})
    end

    test "are exposed on /metrics" do
      # /metrics also reports ledger reconciliation, which queries the database.
      # Without a sandbox connection those gauges fail and log ownership errors
      # -- passing, but reading like a fault.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

      conn =
        Plug.Test.conn(:get, "/metrics")
        |> LowendinsightGet.Endpoint.call(LowendinsightGet.Endpoint.init([]))

      assert conn.resp_body =~ "lei_trending_report_completed"
    end
  end
end
