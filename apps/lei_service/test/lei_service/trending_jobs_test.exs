defmodule LeiService.TrendingJobsTest do
  @moduledoc """
  Trending and cache cleaning are Oban jobs, on their own queues.

  Both ran under Quantum, in the process serving requests: a run was lost on
  every restart, nothing recorded that it had happened, and fourteen
  languages of clones competed with request handling until the machine was
  OOM-killed (#158). One job per language on a queue of concurrency 1 keeps
  one analysis at a time, and keeps a 95-minute whole-run job -- longer than
  Lifeline's rescue window -- from existing at all (ADR-004 step 6).
  """
  use ExUnit.Case, async: false

  alias LeiService.{CacheCleanerWorker, TrendingRefreshWorker, TrendingScheduleWorker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    saved = Application.get_env(:lei_service, :trending_jobs)
    on_exit(fn -> Application.put_env(:lei_service, :trending_jobs, saved || []) end)
    :ok
  end

  defp queued do
    Ecto.Adapters.SQL.query!(
      LeiService.Repo,
      "SELECT worker, queue, args->>'language' FROM oban_jobs ORDER BY id",
      []
    ).rows
  end

  describe "the schedule job" do
    test "queues one refresh per due language, on the trending queue" do
      Application.put_env(:lei_service, :trending_jobs, due: fn _opts -> ["elixir", "rust"] end)

      assert TrendingScheduleWorker.perform(%Oban.Job{args: %{}}) == :ok

      assert queued() == [
               ["LeiService.TrendingRefreshWorker", "trending", "elixir"],
               ["LeiService.TrendingRefreshWorker", "trending", "rust"]
             ]
    end

    test "queues nothing when no language is due" do
      Application.put_env(:lei_service, :trending_jobs, due: fn _opts -> [] end)
      assert TrendingScheduleWorker.perform(%Oban.Job{args: %{}}) == :ok
      assert queued() == []
    end

    test "force queues every language, which is what the operator trigger asks for" do
      test_pid = self()

      Application.put_env(:lei_service, :trending_jobs,
        due: fn opts ->
          send(test_pid, {:due_opts, opts})
          ["elixir"]
        end
      )

      assert TrendingScheduleWorker.perform(%Oban.Job{args: %{"force" => true}}) == :ok
      assert_received {:due_opts, opts}
      assert Keyword.get(opts, :force) == true
    end

    test "a language already queued is not queued twice" do
      Application.put_env(:lei_service, :trending_jobs, due: fn _ -> ["elixir"] end)
      TrendingScheduleWorker.perform(%Oban.Job{args: %{}})
      TrendingScheduleWorker.perform(%Oban.Job{args: %{}})
      assert length(queued()) == 1
    end
  end

  describe "the per-language refresh job" do
    test "refreshes its own language only" do
      test_pid = self()

      Application.put_env(:lei_service, :trending_jobs,
        refresh: fn language, _opts ->
          send(test_pid, {:refreshed, language})
          {:ok, "uuid"}
        end
      )

      assert TrendingRefreshWorker.perform(%Oban.Job{args: %{"language" => "elixir"}}) == :ok
      assert_received {:refreshed, "elixir"}
    end

    test "a language that cannot be refreshed fails the job, so it is visible and retried" do
      Application.put_env(:lei_service, :trending_jobs,
        refresh: fn _l, _o -> {:error, :no_repositories} end
      )

      assert {:error, reason} =
               TrendingRefreshWorker.perform(%Oban.Job{args: %{"language" => "go"}})

      assert reason =~ "no_repositories"
    end

    test "one language is bounded well below Lifeline's rescue window" do
      minutes = div(TrendingRefreshWorker.timeout(%Oban.Job{args: %{"language" => "go"}}), 60_000)
      rescue_after = Application.get_env(:lei_service, Oban)[:lifeline][:rescue_after]
      {n, :minutes} = rescue_after
      assert minutes < n
    end
  end

  describe "the cache cleaner job" do
    test "cleans, and says so" do
      test_pid = self()

      Application.put_env(:lei_service, :trending_jobs,
        clean: fn ->
          send(test_pid, :cleaned)
          :ok
        end
      )

      assert CacheCleanerWorker.perform(%Oban.Job{args: %{}}) == :ok
      assert_received :cleaned
    end

    test "does nothing when cache cleaning is switched off" do
      saved = Application.get_env(:lei_service, :cache_clean_enable)
      Application.put_env(:lei_service, :cache_clean_enable, false)
      on_exit(fn -> Application.put_env(:lei_service, :cache_clean_enable, saved) end)

      Application.put_env(:lei_service, :trending_jobs,
        clean: fn -> flunk("should not clean") end
      )

      assert CacheCleanerWorker.perform(%Oban.Job{args: %{}}) == :ok
    end
  end
end
