defmodule LeiService.PerRequestQuotaTest do
  @moduledoc """
  A free org's monthly allowance limits what one request can do, not only
  whether a request may start.

  The gate asked UsageTracker for the allowance and got back the number of
  analyses remaining, then compared that number with the request's price in
  credits -- different units -- and, for an org that was not wallet-funded,
  admitted it whatever the comparison said. So a free key with one analysis
  left could submit thousands of URLs in one request and have all of them run.
  The monthly limit only ever refused the request after the one that crossed
  it.

  Driven through LeiService.Endpoint, the deployed stack.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, UsageTracker}
  alias LeiService.Datastore

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    LeiService.Plugs.RateLimiter.clear()
    :ok
  end

  # A free org with `remaining` analyses left of its monthly limit.
  defp free_key(remaining) do
    {:ok, org} =
      ApiKeys.create_org("Per Request #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    limit =
      org.free_tier_analyses_limit ||
        Application.get_env(:lei_service, :free_tier_monthly_limit, 200)

    used = limit - remaining
    if used > 0, do: {:ok, _} = UsageTracker.record_usage(org.id, nil, used, 0)

    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "per-request", ["analyze"])
    {org, raw_key}
  end

  # Cached, so an admitted request is served without the network.
  defp cached_urls(n) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    for _ <- 1..n do
      url = "https://github.com/kitplummer/per-request-#{System.unique_integer([:positive])}"

      Datastore.write_to_cache(url, %{
        data: %{repo: url},
        header: %{end_time: now, start_time: now, uuid: "c"}
      })

      url
    end
  end

  defp sbom_for(urls) do
    %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.4",
      "components" =>
        Enum.map(urls, fn url ->
          %{
            "name" => Path.basename(url),
            "externalReferences" => [%{"type" => "vcs", "url" => url}]
          }
        end)
    }
  end

  defp post(path, body, key) do
    conn(:post, path, body)
    |> put_req_header("authorization", "Bearer " <> key)
    |> LeiService.Endpoint.call(@opts)
  end

  defp used(org),
    do: UsageTracker.get_current_usage(org.id) |> then(&(&1.cache_hits + &1.cache_misses))

  describe "POST /v1/analyze" do
    test "a request for more analyses than remain is refused before any run" do
      {org, key} = free_key(1)
      before = used(org)

      conn = post("/v1/analyze", %{"urls" => cached_urls(3), "cache_mode" => "blocking"}, key)

      assert conn.status == 402
      body = Poison.decode!(conn.resp_body)
      assert body["error"] == "free_tier_quota_exceeded"
      assert body["requested"] == 3
      assert body["remaining"] == 1

      Process.sleep(100)
      assert used(org) == before
    end

    test "a request that fits in what remains is served" do
      {_org, key} = free_key(3)

      conn = post("/v1/analyze", %{"urls" => cached_urls(3), "cache_mode" => "blocking"}, key)

      assert conn.status == 200, conn.resp_body
    end
  end

  describe "POST /v1/analyze/sbom" do
    test "an SBOM naming more repositories than remain is refused" do
      {_org, key} = free_key(2)

      conn = post("/v1/analyze/sbom", %{"sbom" => sbom_for(cached_urls(5))}, key)

      assert conn.status == 402
      assert Poison.decode!(conn.resp_body)["requested"] == 5
    end

    test "an SBOM that fits is served" do
      {_org, key} = free_key(5)

      conn =
        post(
          "/v1/analyze/sbom",
          %{"sbom" => sbom_for(cached_urls(5)), "cache_mode" => "blocking"},
          key
        )

      assert conn.status == 200, conn.resp_body
    end
  end
end
