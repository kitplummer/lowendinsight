defmodule LeiService.FailedAnalysisNotCachedTest do
  @moduledoc """
  An analysis that determined nothing is not remembered as though it had (#255).

  `AnalyzerModule.analyze/3` rescues a failed clone and returns `{:ok, report}`
  with `risk: "undetermined"` and the reason in `data.error`. The rescue is
  right -- one unreachable repository must not fail a batch of two hundred --
  but the result is shaped exactly like a success, and the cache wrote whatever
  it was handed.

  So a network blip became a thirty-day answer: the requester paid a cache miss
  at 50 credits for a report containing nothing, every later request was served
  that nothing at 5 credits, and no retry ever happened because from the cache
  it looked answered. Such reports cannot be repaired afterwards either -- they
  carry no `data.git`, so #242 has nothing to recompute and #244 never applies.

  It surfaced analysing this repository's own dependency tree: `certifi` came
  back `undetermined` with every metric nil, and the run reported 62 analysed,
  0 failed, because that is what the return value said.

  Reaching the real failure through `LeiService.Analysis` needs a URL that
  passes `RemoteUrl.validate/1` -- https, resolvable, public -- and then fails
  to clone, which is a live network call. So the decision itself is tested
  directly here, and the wiring is exercised by the `:network` tagged case.
  """
  use ExUnit.Case, async: false

  alias LeiService.Datastore

  defp url, do: "https://github.com/lei-test/undetermined-#{System.unique_integer([:positive])}"

  # A report exactly as analyze/3 builds one when the clone fails
  # (analyzer_module.ex:243-292): an error, no git block, no results.
  defp failed_report(url) do
    %{
      header: %{repo: url, uuid: "u", library_version: "x"},
      data: %{
        error: "Unable to analyze the repo (#{url}), is this a valid Git repo URL?",
        repo: url,
        git: %{},
        risk: "undetermined",
        project_types: %{"undetermined" => "undetermined"},
        repo_size: "undetermined"
      }
    }
  end

  defp real_report(url) do
    %{
      header: %{repo: url, uuid: "u", end_time: DateTime.utc_now() |> DateTime.to_iso8601()},
      data: %{
        repo: url,
        git: %{"last_commit_date" => "2026-09-01T00:00:00Z", "hash" => "abc"},
        results: %{"contributor_risk" => "low"},
        risk: "low"
      }
    }
  end

  describe "a report that records a failure" do
    test "is not written to the cache" do
      u = url()

      assert {:ok, :not_determined} = Datastore.write_to_cache_if_determined(u, failed_report(u))

      refute Datastore.in_cache?(u),
             "a failed analysis was cached, so the next thirty days of requests are served nothing"
    end

    test "leaves the key free, so the next request is a real attempt" do
      u = url()
      Datastore.write_to_cache_if_determined(u, failed_report(u))
      Datastore.write_to_cache_if_determined(u, failed_report(u))

      refute Datastore.in_cache?(u)
    end

    test "does not overwrite a good report already cached" do
      # The ordering that would otherwise lose a real answer: a repository is
      # analysed successfully, then a later attempt fails transiently.
      u = url()
      {:ok, _} = Datastore.write_to_cache(u, real_report(u))

      Datastore.write_to_cache_if_determined(u, failed_report(u))

      {:ok, json, :hit} = Datastore.get_from_cache(u, 28)
      assert Poison.decode!(json)["data"]["risk"] == "low"

      on_exit(fn -> Datastore.delete_from_cache(u) end)
    end
  end

  describe "a report that records an analysis" do
    # The over-correction to guard against: refusing to cache failures must not
    # become refusing to cache.
    test "is still cached" do
      u = url()

      assert {:ok, _} = Datastore.write_to_cache_if_determined(u, real_report(u))
      assert Datastore.in_cache?(u), "a successful analysis was not cached"

      on_exit(fn -> Datastore.delete_from_cache(u) end)
    end
  end

  describe "telling the two apart" do
    test "a failed report is not determined" do
      refute AnalyzerModule.determined?(failed_report("x"))
    end

    test "a real report is determined" do
      assert AnalyzerModule.determined?(real_report("x"))
    end

    test "string keys, as a report comes back from the cache, work too" do
      round_tripped = failed_report("x") |> Poison.encode!() |> Poison.decode!()
      refute AnalyzerModule.determined?(round_tripped)

      good = real_report("x") |> Poison.encode!() |> Poison.decode!()
      assert AnalyzerModule.determined?(good)
    end

    test "anything that is not a report is not determined" do
      # Absence of an error is not evidence of an analysis. Defaulting the
      # other way would let an empty or malformed value through as a result.
      refute AnalyzerModule.determined?(%{})
      refute AnalyzerModule.determined?(%{"data" => nil})
      refute AnalyzerModule.determined?(nil)
      refute AnalyzerModule.determined?("")
    end
  end

  describe "the analysis path uses it" do
    # Reaching this at runtime needs a live clone failure, so the call site is
    # asserted directly -- the same approach the monitor wiring tests take for
    # things a unit test cannot drive. Without it the guarded write could be
    # swapped back for the bare one and every test above would still pass.
    @source Path.expand("../../lib/lei_service/analysis.ex", __DIR__)

    test "analyze_remote caches through the guarded write, not the bare one" do
      source = File.read!(@source)

      assert source =~ "Datastore.write_to_cache_if_determined(url, rep)",
             "the analysis path does not use the guarded write"

      refute source =~ ~r/Datastore\.write_to_cache\(url, rep\)/,
             "the analysis path still writes the report unconditionally"
    end
  end

  describe "through the real analysis path" do
    @tag :network
    test "a repository that cannot be cloned is not cached" do
      u = url()

      LeiService.Analysis.analyze(u, "test", %{types: false})

      refute Datastore.in_cache?(u)
    end
  end
end
