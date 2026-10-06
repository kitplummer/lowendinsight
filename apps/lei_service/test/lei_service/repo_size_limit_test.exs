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

  describe "the default limit, with nothing configured" do
    test "is derived from disk, not chosen" do
      # The guard bounds concurrent clone space on a root filesystem with no
      # volume and no quota. Every input is measured:
      #
      #   free disk 7,300,000 KB / concurrency 5 x 60% margin = 876,000 KB
      #   per slot, divided by the 1.73x by which GitHub's `size` understates a
      #   full clone (DefinitelyTyped 809 -> 1,400 MB) = 506,358 KB.
      Application.delete_env(:lei_service, :max_repo_size_kb)

      free_disk_kb = 7_300_000
      concurrency = 5
      margin = 0.6
      understatement = 1.73

      derived = free_disk_kb * margin / concurrency / understatement

      assert RepoSize.limit_kb() <= derived,
             "the limit exceeds what the disk arithmetic allows (#{trunc(derived)} KB)"

      assert RepoSize.limit_kb() * concurrency * understatement < free_disk_kb,
             "#{concurrency} concurrent clones at the limit would not fit on disk"
    end

    test "admits the repositories the quadratic fix made cheap" do
      # pandas, jest and django were refused when analysis was slow. It is not
      # any more -- DefinitelyTyped analyses in 15.5 s -- so the only question
      # left is disk, and these fit.
      Application.delete_env(:lei_service, :max_repo_size_kb)

      for {name, kb} <- [pandas: 415_998, jest: 324_245, django: 282_624] do
        assert RepoSize.check("https://github.com/x/#{name}", sized(kb)) == :ok,
               "#{name} at #{kb} KB is refused though it now analyses in seconds and fits on disk"
      end
    end

    test "still refuses what no safe gate can admit" do
      # Five concurrent DefinitelyTyped clones is 95.9% of free disk. These
      # need the concurrent disk bounded directly -- a smaller queue for large
      # repositories, or a semaphore on bytes in flight -- not a larger number
      # here.
      Application.delete_env(:lei_service, :max_repo_size_kb)

      for {name, kb} <- [definitely_typed: 809_000, react: 1_100_996, typescript: 2_888_370] do
        assert {:too_large, _, _} = RepoSize.check("https://github.com/x/#{name}", sized(kb)),
               "#{name} at #{kb} KB is admitted, and five concurrent would not fit on disk"
      end
    end
  end

  describe "a renamed repository" do
    # GitHub answers a renamed repository with 301 and the new location rather
    # than the record:
    #
    #     GET /repos/facebook/react
    #     301 {"message": "Moved Permanently",
    #          "url": "https://api.github.com/repositories/10270250"}
    #
    # React moved to `react/react`. Without `follow_redirect` the 301 body
    # carries no `size`, `get_repo_size/1` returns `{nil, url}`, and `check/2`
    # answers `:unknown` -- which is **allowed through**. The guard did not
    # fail; it silently stopped guarding, for every renamed repository, one of
    # which is among the most depended upon on GitHub.
    #
    # These drive the decision, not the HTTP call: a 301 body is what the
    # client produces without the option, and it must not read as "no size".
    test "a 301 body is not a size, and must not pass as one" do
      moved = fn url ->
        # What Poison.decode of the 301 body yields: no "size" key, so
        # get_repo_size/1 falls to its else clause.
        {nil, url}
      end

      # This is the state the bug produced. It is `:unknown`, and `:unknown` is
      # permissive by design -- which is exactly why the client must not create
      # it by accident.
      assert RepoSize.check("https://github.com/facebook/react", moved) == :unknown
    end

    test "with the redirect followed, the real size is compared" do
      # react/react is 1,100,996 KB, measured against the live API with
      # follow_redirect. The point is that a size is compared at all, rather
      # than the comparison being skipped -- so this sets the production limit
      # instead of the small one this file's setup uses, because the whole
      # question is whether React falls under it.
      Application.put_env(:lei_service, :max_repo_size_kb, 1_500_000)
      followed = fn url -> {1_100_996, url} end

      assert RepoSize.check("https://github.com/facebook/react", followed) == :ok

      # And the same size is refused when the limit is below it, which is what
      # tells us the value is being read rather than ignored.
      Application.put_env(:lei_service, :max_repo_size_kb, 1_000_000)

      assert RepoSize.check("https://github.com/facebook/react", followed) ==
               {:too_large, 1_100_996, 1_000_000}
    end

    test "the client asks for redirects to be followed" do
      # The behaviour above depends on one option, and the lesson was already
      # learned in the study tooling before the service got it. Asserted here
      # because no injected `size_fn` can catch its absence -- the injection
      # point is below the HTTP call.
      source = File.read!(Path.expand("../../lib/lei_service/github_trending.ex", __DIR__))

      [call] =
        Regex.run(~r/defp fetch_gh_api_response.*?\n  end/s, source) ||
          flunk("fetch_gh_api_response/2 not found")

      assert call =~ "follow_redirect: true",
             "the size lookup does not follow GitHub's 301 for a renamed repository, " <>
               "so the size guard is skipped for every one of them"
    end

    test "the sbom fetch follows them too" do
      source =
        File.read!(Path.expand("../../lib/mix/tasks/lei.cache_baseline.ex", __DIR__))

      assert source =~ "follow_redirect: true",
             "the SBOM fetch does not follow a rename, so a renamed repository " <>
               "reads as publishing no SBOM"
    end
  end
end
