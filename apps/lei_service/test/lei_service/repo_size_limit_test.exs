defmodule LeiService.RepoSizeLimitTest do
  @moduledoc """
  A repository too large to analyse is refused before it is cloned (#265).

  `GithubTrending.keep_repo?/2` has capped candidates since #162, when a 1 GB
  limit on a machine with 459 MB of memory let 671 MB and 411 MB repositories
  through. That guard covers the path we drive. The customer path had none, so
  any caller could name a repository of any size and the clone would land in
  `LEI_BASE_TEMP_DIR` -- the root filesystem, no volume, no quota -- beside up
  to four others.

  The check happens before the clone because the clone is the cost being
  avoided. Checking afterwards would protect nothing.

  `size_fn` is injected throughout, so none of this reaches GitHub.
  """
  use ExUnit.Case, async: false

  alias Lei.RepoSize

  defp sized(kb), do: fn url -> {kb, url} end
  defp unmeasurable, do: fn url -> {nil, url} end

  setup do
    original = Application.fetch_env(:lei_service, :max_repo_size_kb)
    Application.put_env(:lei_service, :max_repo_size_kb, 1_000)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:lei_service, :max_repo_size_kb, v)
        :error -> Application.delete_env(:lei_service, :max_repo_size_kb)
      end
    end)

    :ok
  end

  describe "deciding" do
    test "a repository over the limit is refused" do
      assert {:too_large, 5_000, 1_000} = RepoSize.check("https://github.com/x/big", sized(5_000))
    end

    test "a repository under the limit is allowed" do
      assert :ok = RepoSize.check("https://github.com/x/small", sized(10))
    end

    test "exactly at the limit is refused" do
      # The boundary is a decision, not an accident: the limit is the first
      # size not analysed.
      assert {:too_large, 1_000, 1_000} =
               RepoSize.check("https://github.com/x/edge", sized(1_000))
    end

    test "a size we cannot measure is allowed through" do
      # Deliberately the opposite of trending, which refuses what it cannot
      # measure. Trending picks its own candidates; a customer naming a GitLab
      # repository is asking a fair question, and refusing it would break far
      # more than it protects.
      assert :unknown = RepoSize.check("https://gitlab.com/x/y", unmeasurable())
    end
  end

  describe "the limit itself" do
    test "is configurable" do
      Application.put_env(:lei_service, :max_repo_size_kb, 42)
      assert RepoSize.limit_kb() == 42
    end

    test "is not trending's dial" do
      # Sharing one would mean tuning the customer path moved trending with it,
      # though they refuse different things for different reasons.
      Application.put_env(:lei_service, :max_repo_size_kb, 42)
      Application.put_env(:lei_service, :trending_max_repo_size_kb, 999_999)

      on_exit(fn -> Application.delete_env(:lei_service, :trending_max_repo_size_kb) end)

      assert RepoSize.limit_kb() == 42
    end
  end

  describe "the refusal" do
    test "is not mistaken for an analysis" do
      # AnalyzerModule.determined?/1 is what keeps it out of the cache and off
      # the bill (#256). If this ever reads as determined, a refusal becomes a
      # thirty-day cached answer that the requester paid for.
      refusal = RepoSize.refusal("https://github.com/x/big", 5_000, 1_000)

      refute AnalyzerModule.determined?(refusal)
      assert refusal[:data][:risk] == "undetermined"
    end

    test "says how far over the limit it was" do
      refusal = RepoSize.refusal("https://github.com/x/big", 5_000, 1_000)

      assert refusal[:data][:error] =~ "5000"
      assert refusal[:data][:error] =~ "1000"
      assert refusal[:data][:repo_size] == 5_000
    end

    test "survives the round trip a report makes" do
      json = RepoSize.refusal("https://github.com/x/big", 5_000, 1_000) |> Poison.encode!()

      refute AnalyzerModule.determined?(Poison.decode!(json))
    end
  end

  describe "the analysis path asks before cloning" do
    # Reaching this at runtime needs a repository large enough to matter, which
    # is exactly the clone being avoided. The call site is asserted instead,
    # the same approach the monitor wiring tests take.
    @source Path.expand("../../lib/lei_service/analysis.ex", __DIR__)

    test "the check precedes AnalyzerModule.analyze" do
      source = File.read!(@source)

      assert source =~ "Lei.RepoSize.check(url)",
             "the analysis path does not check size"

      check_at = :binary.match(source, "Lei.RepoSize.check(url)") |> elem(0)

      analyze_at =
        :binary.match(source, "AnalyzerModule.analyze(url, source, options)") |> elem(0)

      assert check_at < analyze_at,
             "size is checked after the clone, which protects nothing"
    end

    test "a refusal is returned rather than raised" do
      # One oversized repository in a manifest of two hundred must not fail the
      # batch -- the same reason AnalyzerModule rescues a failed clone.
      source = File.read!(@source)

      assert source =~ "{:ok, Lei.RepoSize.refusal(url, size_kb, limit_kb), :miss}"
    end
  end
end
