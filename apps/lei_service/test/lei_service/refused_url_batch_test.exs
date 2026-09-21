defmodule LeiService.RefusedUrlBatchTest do
  @moduledoc """
  One refused URL does not take the rest of the batch with it (#257).

  `analyze/3` re-checks `RemoteUrl.validate/1` after the route already did —
  deliberately, so the rule on what may be cloned is enforced here as well as
  there, and the comment says as much. It answers `{:error, reason}` when it
  refuses, which is a two-tuple where the success path is a three-tuple. A
  single clause matching only the latter raised `FunctionClauseError` and
  failed the whole job:

      ** (FunctionClauseError) no function clause matching in
         anonymous fn/1 in LeiService.Analysis.process/3

  The guard was working. Its failure handling was not — and the case it fires
  in is exactly the one it exists for: the route's check and this one
  disagreeing, which is what happens when a name resolves differently by the
  time the worker runs it.

  Reproduced while writing tests for #255, with `"not-a-url"`.
  """
  use ExUnit.Case, async: false

  alias LeiService.Analysis

  defp good, do: "https://github.com/kitplummer/lowendinsight"

  defp uuid, do: Ecto.UUID.generate()

  defp repos(report), do: report[:report][:repos]

  defp statuses(report), do: report[:metadata][:cache_status][:per_repo]

  describe "a batch containing a URL the rule refuses" do
    test "does not raise", %{} do
      # The defect. Everything else here is about what it does instead.
      assert {:ok, _report} =
               Analysis.process(
                 uuid(),
                 ["not-a-url", "http://insecure.example.com"],
                 DateTime.utc_now()
               )
    end

    test "reports the refused one rather than dropping it" do
      {:ok, report} = Analysis.process(uuid(), ["not-a-url"], DateTime.utc_now())

      # Dropping it would shorten the list a caller reads to decide what
      # happened, and a shorter list reads as less to look at.
      assert length(repos(report)) == 1
    end

    test "the refused entry says it was not analysed" do
      {:ok, report} = Analysis.process(uuid(), ["not-a-url"], DateTime.utc_now())

      [entry] = repos(report)

      refute AnalyzerModule.determined?(entry),
             "a refusal reads as an analysis, so it would be cached and billed"

      assert entry[:data][:error] =~ "Not analysed"
      assert entry[:data][:risk] == "undetermined"
    end

    test "is counted as neither a hit nor a miss" do
      # Both are billing categories. This is a repository we declined to look
      # at, not one we looked at cheaply or expensively.
      {:ok, report} = Analysis.process(uuid(), ["not-a-url"], DateTime.utc_now())

      cache = report[:metadata][:cache_status]

      assert cache[:hits] == 0
      assert cache[:misses] == 0
      assert statuses(report) == ["refused"]
    end
  end

  describe "a batch of several refusals" do
    test "every one is reported" do
      urls = ["not-a-url", "ftp://example.com/x", "http://plain.example.com"]

      {:ok, report} = Analysis.process(uuid(), urls, DateTime.utc_now())

      assert length(repos(report)) == 3
      assert statuses(report) == ["refused", "refused", "refused"]
      assert Enum.all?(repos(report), &(not AnalyzerModule.determined?(&1)))
    end

    test "each refusal names the URL it refused" do
      # Results arrive in order without carrying their input, so the zip is
      # what keeps a refusal attached to what was refused.
      urls = ["not-a-url", "ftp://example.com/x"]

      {:ok, report} = Analysis.process(uuid(), urls, DateTime.utc_now())

      assert Enum.map(repos(report), & &1[:data][:repo]) == urls
    end
  end

  describe "the case this actually guards: the two checks disagreeing" do
    # The reproduction that matters. "not-a-url" above exercises the clause but
    # the route would reject it too, so it never reaches a worker in practice.
    #
    # This is a URL the route admits and the worker refuses -- the window
    # RemoteUrl's own moduledoc names, where a name answers differently between
    # two lookups. analyze/3 calls validate/1 with no opts, so the resolver is
    # driven through configuration.
    setup do
      original = Application.fetch_env(:lei_service, :remote_url_resolver)

      on_exit(fn ->
        case original do
          {:ok, v} -> Application.put_env(:lei_service, :remote_url_resolver, v)
          :error -> Application.delete_env(:lei_service, :remote_url_resolver)
        end
      end)

      :ok
    end

    @admitted "https://github.com/kitplummer/lowendinsight"

    defp public_resolver, do: fn _host -> {:ok, [{140, 82, 121, 3}]} end
    defp rebound_resolver, do: fn _host -> {:ok, [{127, 0, 0, 1}]} end

    test "the route would admit this URL" do
      # Establishes the premise: without it, the test below is just another
      # invalid URL and proves nothing about the disagreement.
      assert :ok =
               LeiService.RemoteUrl.validate(@admitted, resolve: public_resolver())
    end

    test "and the worker refuses it, without failing the batch" do
      Application.put_env(:lei_service, :remote_url_resolver, rebound_resolver())

      assert :ok != LeiService.RemoteUrl.validate(@admitted),
             "the premise is broken: the worker-time check now admits it too"

      assert {:ok, report} = Analysis.process(uuid(), [@admitted], DateTime.utc_now())

      assert statuses(report) == ["refused"]
      assert length(repos(report)) == 1
      refute AnalyzerModule.determined?(hd(repos(report)))
    end

    test "the rest of the batch still gets answers" do
      # The actual damage the crash did: one refusal took every other
      # repository in the job with it.
      #
      # The surviving URL is seeded into the cache so this is a hit rather than
      # a clone. Without that it passed locally in 0.06s off a warm Redis and
      # would have made a real network request in CI -- slow, and flaky for
      # reasons having nothing to do with what is being tested.
      good = "https://github.com/lei-test/survivor-#{System.unique_integer([:positive])}"

      {:ok, _} =
        LeiService.Datastore.write_to_cache(good, %{
          "header" => %{
            "repo" => good,
            "uuid" => "u",
            "end_time" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          "data" => %{
            "repo" => good,
            "git" => %{"hash" => "abc", "last_commit_date" => "2026-09-01T00:00:00Z"},
            "results" => %{"contributor_risk" => "low"},
            "risk" => "low"
          }
        })

      on_exit(fn -> LeiService.Datastore.delete_from_cache(good) end)

      Application.put_env(:lei_service, :remote_url_resolver, fn
        "private.example.com" -> {:ok, [{10, 0, 0, 1}]}
        _ -> {:ok, [{140, 82, 121, 3}]}
      end)

      urls = ["https://private.example.com/a/b", good]

      assert {:ok, report} = Analysis.process(uuid(), urls, DateTime.utc_now())

      assert length(repos(report)) == 2

      assert statuses(report) == ["refused", "hit"],
             "the surviving URL was not answered, so the batch was not really processed"

      assert report[:metadata][:cache_status][:hits] == 1
    end
  end

  describe "a batch with nothing wrong" do
    @tag :network
    test "is unaffected" do
      {:ok, report} = Analysis.process(uuid(), [good()], DateTime.utc_now())

      assert length(repos(report)) == 1
      refute "refused" in statuses(report)
    end
  end
end
