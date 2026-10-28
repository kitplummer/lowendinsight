defmodule Lei.AnalyzeTest do
  @moduledoc """
  `Lei.Analyze` runs `/v1/analyze`'s request without a conn.

  MCP's `analyze_repositories` needs the route's validation, price, refund and
  billing block, answered as values rather than HTTP. These tests call the
  module directly, the way a second entry point will; the route's own
  behaviour stays covered by the endpoint tests.
  """
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Analyze #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, _raw, api_key} = ApiKeys.create_api_key(org, "k", ["analyze"])

    %{org: org, api_key: Repo.preload(api_key, :org)}
  end

  defp unique_url(name),
    do: "https://github.com/kitplummer/#{name}-#{System.unique_integer([:positive])}"

  defp cached_url do
    url = unique_url("analyze-cached")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    LeiService.Datastore.write_to_cache(url, %{
      data: %{repo: url},
      header: %{end_time: now, start_time: now, uuid: "analyze-core"}
    })

    url
  end

  # Work goes through Oban, which tests run in :manual mode: queued, not run.
  defp use_workers! do
    saved = Application.get_env(:lei_service, :use_workers)
    Application.put_env(:lei_service, :use_workers, true)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:lei_service, :use_workers),
        else: Application.put_env(:lei_service, :use_workers, saved)
    end)
  end

  defp context(api_key) do
    %{
      uuid: UUID.uuid4(),
      start_time: DateTime.utc_now(),
      route: "/v1/analyze",
      api_key: api_key
    }
  end

  describe "validate/1" do
    test "a body without a urls list is refused" do
      assert {:invalid, %{error: "POST body must contain a 'urls' list"}} =
               Lei.Analyze.validate(%{})

      assert {:invalid, _} = Lei.Analyze.validate(%{"urls" => "https://github.com/a/b"})
    end

    test "an unknown cache_mode is refused" do
      assert {:invalid, %{error: "invalid cache_mode: 'eventually'" <> _}} =
               Lei.Analyze.validate(%{
                 "urls" => ["https://github.com/kitplummer/xmpp4rails"],
                 "cache_mode" => "eventually"
               })
    end

    test "a valid request comes back with its defaults filled in" do
      url = "https://github.com/kitplummer/xmpp4rails"

      assert {:ok, %{urls: [^url], cache_mode: "blocking", cache_timeout: timeout}} =
               Lei.Analyze.validate(%{"urls" => [url]})

      assert is_integer(timeout)
    end
  end

  describe "price/1" do
    test "an uncached repository is one miss, and admission is told so" do
      assert {{0, 1}, admission} = Lei.Analyze.price([unique_url("analyze-price")])
      assert admission[:usage] == {0, 1}
      assert admission[:required_credits] > 0
    end

    test "a cached repository is one hit" do
      assert {{1, 0}, _admission} = Lei.Analyze.price([cached_url()])
    end
  end

  describe "run/4" do
    test "an API key's result carries the billing block", ctx do
      {:ok, request} = Lei.Analyze.validate(%{"urls" => [cached_url()]})
      billing = {ctx.org.id, ctx.api_key.id, ctx.org.tier}

      assert {:ok, body} = Lei.Analyze.run(request, billing, {1, 0}, context(ctx.api_key))

      assert %{"billing" => %{"cache_hits" => 1, "tier" => "free"}} = Poison.decode!(body)
    end

    test "without an API key there is no billing block" do
      {:ok, request} = Lei.Analyze.validate(%{"urls" => [cached_url()]})

      assert {:ok, body} = Lei.Analyze.run(request, {nil, nil, nil}, {1, 0}, context(nil))

      refute Map.has_key?(Poison.decode!(body), "billing")
    end

    test "the billing block reports what admission charged, not what the response counted",
         ctx do
      # An async request answers with a partial report whose metadata carries
      # no cache counts. Admission charged the miss before any work ran (#152),
      # so a block built from the response told the caller it cost nothing.
      use_workers!()

      {:ok, request} =
        Lei.Analyze.validate(%{
          "urls" => [unique_url("analyze-async")],
          "cache_mode" => "async"
        })

      {split, _admission} = Lei.Analyze.price(request.urls)
      assert split == {0, 1}
      billing = {ctx.org.id, ctx.api_key.id, ctx.org.tier}

      assert {:ok, body} = Lei.Analyze.run(request, billing, split, context(ctx.api_key))

      expected = Lei.UsageTracker.calculate_cost(0, 1) |> Decimal.to_float()

      assert %{"billing" => %{"cache_hits" => 0, "cache_misses" => 1, "cost_cents" => ^expected}} =
               Poison.decode!(body)
    end

    test "work that cannot be queued is credited back and reported", ctx do
      use_workers!()

      # The real failure, as AnalyzeUnqueuedCreditTest produces it: undone with
      # the test's transaction.
      Ecto.Adapters.SQL.query!(LeiService.Repo, "DROP TABLE oban_jobs CASCADE", [])

      {:ok, request} = Lei.Analyze.validate(%{"urls" => [unique_url("analyze-unqueued")]})
      billing = {ctx.org.id, ctx.api_key.id, ctx.org.tier}

      assert {:not_queued, %{error: "analysis_not_queued", credits_returned: credits}} =
               Lei.Analyze.run(request, billing, {0, 1}, context(ctx.api_key))

      assert credits > 0

      assert [entry] =
               ctx.org.id
               |> Credits.entries()
               |> Enum.filter(&(&1.reason == "adjustment:unqueued"))

      assert entry.delta == credits
      assert entry.metadata["route"] == "/v1/analyze"
    end
  end
end
