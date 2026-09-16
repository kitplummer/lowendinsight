defmodule LeiService.BatchDependencyWorkerTest do
  @moduledoc """
  A batch miss becomes a real job that analyses the package's repository.

  The batch endpoint marked misses "pending" with an invented id and queued
  nothing, so the analysis a caller paid for never ran (ADR-004 step 4).
  """
  use ExUnit.Case, async: false

  alias LeiService.BatchDependencyWorker

  setup do
    Lei.BatchCache.clear()

    saved = Application.get_env(:lei_service, :batch_dependency)
    on_exit(fn -> Application.put_env(:lei_service, :batch_dependency, saved || []) end)
    :ok
  end

  defp configure(resolve, analyze) do
    Application.put_env(:lei_service, :batch_dependency, resolve: resolve, analyze: analyze)
  end

  defp job(args), do: %Oban.Job{args: args, attempt: 1, max_attempts: 3}

  @dep %{"ecosystem" => "npm", "package" => "left-pad", "version" => "1.3.0"}

  test "resolves the package, analyses its repository, and caches the report" do
    test_pid = self()

    configure(
      fn "npm", "left-pad", _opts -> {:ok, "https://github.com/o/left-pad"} end,
      fn url ->
        send(test_pid, {:analyzed, url})
        {:ok, %{data: %{risk: "low", repo: url}, header: %{}}}
      end
    )

    assert BatchDependencyWorker.perform(job(@dep)) == :ok
    assert_received {:analyzed, "https://github.com/o/left-pad"}

    assert {:ok, entry} = Lei.BatchCache.get("npm", "left-pad", "1.3.0")
    assert entry.result.data.risk == "low"
  end

  test "the cached report replaces the pending marker, so the next batch is a hit" do
    Lei.BatchCache.put("npm", "left-pad", "1.3.0", %{status: "pending", job_id: "1"}, ttl: 300)

    configure(
      fn _, _, _ -> {:ok, "https://github.com/o/left-pad"} end,
      fn _url -> {:ok, %{data: %{risk: "high"}, header: %{}}} end
    )

    assert BatchDependencyWorker.perform(job(@dep)) == :ok
    assert {1, 0} = Lei.BatchAnalyzer.cache_split([@dep])
  end

  test "a package with no repository is cancelled, not retried forever" do
    configure(fn _, _, _ -> {:error, :no_repository} end, fn _ -> flunk("should not analyse") end)
    assert {:cancel, reason} = BatchDependencyWorker.perform(job(@dep))
    assert reason =~ "no_repository"
  end

  test "an ecosystem we cannot resolve is cancelled" do
    configure(
      fn _, _, _ -> {:error, {:unsupported_ecosystem, "cocoapods"}} end,
      fn _ -> flunk("should not analyse") end
    )

    assert {:cancel, _} = BatchDependencyWorker.perform(job(%{@dep | "ecosystem" => "cocoapods"}))
  end

  test "a registry that is down is retried, not cancelled" do
    configure(fn _, _, _ -> {:error, {:unreachable, :timeout}} end, fn _ ->
      flunk("no analysis")
    end)

    assert {:error, reason} = BatchDependencyWorker.perform(job(@dep))
    assert reason =~ "unreachable"
  end

  test "the job is bounded, below Lifeline's rescue window" do
    timeout = BatchDependencyWorker.timeout(job(@dep))
    assert timeout > 0
    assert div(timeout, 60_000) < 60
  end
end
