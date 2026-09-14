defmodule LowendinsightGet.UnbilledPathsTest do
  @moduledoc """
  Every path that runs an analysis is paid for or bounded (#152).

  Three were not:
  - POST /v1/analyze/sbom checked no quota and recorded no usage
  - /v1/analyze billed from the response's cache counts, which async, stale
    and timed-out requests do not carry, so they recorded nothing
  - the homepage's Try It form ran fresh analyses for anyone, unbounded

  Driven through LowendinsightGet.Endpoint, the deployed stack.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, Wallets}
  alias LowendinsightGet.Datastore

  @opts LowendinsightGet.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    LowendinsightGet.Plugs.RateLimiter.clear()

    saved =
      for k <- [:default_top_up_credits, :rate_limits],
          do: {k, Application.fetch_env(:lowendinsight, k)}

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:lowendinsight, k, value)
          :error -> Application.delete_env(:lowendinsight, k)
        end
      end
    end)

    :ok
  end

  defp wallet_key(balance) do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)
    if balance > 0, do: {:ok, _} = Credits.grant(org.id, balance, "adjustment:manual")
    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "unbilled-test", ["analyze"])
    {org, raw_key}
  end

  defp cached_url do
    url = "https://github.com/kitplummer/unbilled-cached-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Datastore.write_to_cache(url, %{
      data: %{repo: url},
      header: %{end_time: now, start_time: now, uuid: "c"}
    })

    url
  end

  # A URL nothing has analysed. Admission is decided before any work, so the
  # tests below that are refused never reach the network.
  defp uncached_url do
    url = "https://github.com/kitplummer/unbilled-uncached-#{System.unique_integer([:positive])}"
    Datastore.delete_from_cache(url)
    url
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
    |> then(fn c -> if key, do: put_req_header(c, "authorization", "Bearer " <> key), else: c end)
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  defp settle_balance(org_id, expected) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      b = Credits.balance(org_id)
      if b == expected, do: {:halt, b}, else: Process.sleep(20) && {:cont, b}
    end)
  end

  describe "POST /v1/analyze/sbom" do
    test "a wallet org with no credits is asked to pay, not served" do
      {_org, key} = wallet_key(0)
      conn = post("/v1/analyze/sbom", %{"sbom" => sbom_for([cached_url()])}, key)

      assert conn.status == 402
    end

    test "a funded org is debited for every repository the SBOM names" do
      {org, key} = wallet_key(1_000)
      urls = [cached_url(), cached_url()]

      conn =
        post("/v1/analyze/sbom", %{"sbom" => sbom_for(urls), "cache_mode" => "blocking"}, key)

      assert conn.status == 200, conn.resp_body

      # Two cache hits at 5 credits each.
      assert settle_balance(org.id, 990) == 990
    end

    test "an agent with no credentials is asked to pay, not told to authenticate" do
      conn = post("/v1/analyze/sbom", %{"sbom" => sbom_for([cached_url()])}, nil)
      assert conn.status == 402
    end
  end

  describe "billing does not depend on the analysis finishing in the request" do
    test "an async analysis of an uncached repository is debited as a miss when accepted" do
      # The response is a partial report with no cache counts. Billed from
      # the response, this recorded nothing and the report was fetched later
      # for free.
      {org, key} = wallet_key(1_000)
      url = uncached_url()

      conn = post("/v1/analyze", %{"urls" => [url], "cache_mode" => "async"}, key)
      assert conn.status in [200, 202], conn.resp_body

      assert settle_balance(org.id, 950) == 950
    end

    test "a balance smaller than the request is asked to top up, not run into debt" do
      Application.put_env(:lowendinsight, :default_top_up_credits, 10)
      {org, key} = wallet_key(30)

      # One uncached repository costs 50 credits; the org holds 30.
      conn = post("/v1/analyze", %{"urls" => [uncached_url()], "cache_mode" => "async"}, key)

      assert conn.status == 402
      # The top-up covers the shortfall even though it exceeds the default block.
      # A keyed org is offered the card rail in test config (a profile is set),
      # so a challenge is issued and its size is observable. Exactly the
      # shortfall: 50 needed, 30 held, default block of 10.
      body = Poison.decode!(conn.resp_body)
      assert body["credits"] == 20, conn.resp_body
      assert Credits.balance(org.id) == 30
    end

    test "a request made entirely of cached repositories costs hits, not misses" do
      {org, key} = wallet_key(1_000)

      conn = post("/v1/analyze", %{"urls" => [cached_url(), cached_url(), cached_url()]}, key)
      assert conn.status == 200, conn.resp_body

      assert settle_balance(org.id, 985) == 985
    end
  end

  describe "the Try It form" do
    defp try_it(url) do
      conn(:get, "/url=" <> URI.encode_www_form(url)) |> LowendinsightGet.Endpoint.call(@opts)
    end

    defp exhaust_try_it do
      limits = Application.get_env(:lowendinsight, :rate_limits, %{})
      limit = Map.get(limits, :try_it, 10)
      for _ <- 1..limit, do: Lei.RateLimiter.check("try_it:127.0.0.1", "try_it")
    end

    test "a fresh analysis beyond the per-IP limit is refused before any work" do
      exhaust_try_it()
      conn = try_it(uncached_url())

      assert conn.status == 429
      assert conn.resp_body =~ "/v1/analyze"
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "a cached report is still served when the limit is reached" do
      url = cached_url()
      exhaust_try_it()

      assert try_it(url).status == 200
    end

    test "cached reports do not count against the limit" do
      Application.put_env(
        :lowendinsight,
        :rate_limits,
        Map.put(Application.get_env(:lowendinsight, :rate_limits, %{}), :try_it, 1)
      )

      url = cached_url()
      for _ <- 1..5, do: assert(try_it(url).status == 200)

      # The single fresh allowance is untouched.
      assert {:ok, 0} = Lei.RateLimiter.check("try_it:127.0.0.1", "try_it")
    end
  end
end
