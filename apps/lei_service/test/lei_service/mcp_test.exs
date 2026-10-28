defmodule LeiService.McpTest do
  @moduledoc """
  `/mcp`: the analysis as a remote MCP server.

  Until now the only MCP server was `clients/mcp/lei_mcp.py`, run locally
  over stdio, which an agent's user had to download, wire up and keep. Remote
  clients connect to a URL. This is Streamable HTTP, stateless, answering JSON
  rather than opening event streams: every call is a request and a response,
  which is all a tool that looks something up needs.

  Driven through `LeiService.Endpoint`, which is what production serves. A
  route that works against its own module and is never reached through the
  endpoint is the failure this codebase has had (#147).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Repo, UsageTracker}

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    Lei.BatchCache.clear()

    # Queued work is not run here: a miss is reported pending with a job id.
    saved = Application.get_env(:lei_service, :batch_scheduler)
    Application.put_env(:lei_service, :batch_scheduler, fn _dep -> {:ok, "job-1"} end)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:lei_service, :batch_scheduler),
        else: Application.put_env(:lei_service, :batch_scheduler, saved)

      Lei.RateLimiter.clear()
    end)

    {org, key} = org_with_key(["analyze"])
    %{org: org, key: key}
  end

  defp org_with_key(scopes, attrs \\ []) do
    {:ok, org} =
      ApiKeys.create_org("Mcp #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    org = org |> Ecto.Changeset.change(attrs) |> Repo.update!()
    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "k", scopes)
    {org, raw_key}
  end

  defp mcp(body, headers) do
    conn =
      conn(:post, "/mcp", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> LeiService.Endpoint.call(@opts)
  end

  defp rpc(key, method, params \\ %{}, id \\ 1) do
    conn =
      mcp(%{jsonrpc: "2.0", id: id, method: method, params: params}, [
        {"authorization", "Bearer " <> key}
      ])

    assert conn.status == 200, "#{method}: #{conn.status} #{conn.resp_body}"
    Poison.decode!(conn.resp_body)
  end

  defp call_tool(key, name, arguments),
    do: rpc(key, "tools/call", %{name: name, arguments: arguments})["result"]

  @dep %{"ecosystem" => "npm", "package" => "left-pad", "version" => "1.3.0"}

  describe "the protocol" do
    test "initialize answers with the server and its tools capability", %{key: key} do
      body = rpc(key, "initialize", %{protocolVersion: "2025-06-18", capabilities: %{}})

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["capabilities"]["tools"]
      assert body["result"]["serverInfo"]["name"] == "lowendinsight"
    end

    test "a protocol version it does not know is answered with its own", %{key: key} do
      body = rpc(key, "initialize", %{protocolVersion: "1999-01-01", capabilities: %{}})

      assert body["result"]["protocolVersion"] in Lei.Mcp.protocol_versions()
    end

    test "a notification is accepted with no body", %{key: key} do
      conn =
        mcp(%{jsonrpc: "2.0", method: "notifications/initialized"}, [
          {"authorization", "Bearer " <> key}
        ])

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "tools/list offers each tool, with a schema", %{key: key} do
      tools = Map.new(rpc(key, "tools/list")["result"]["tools"], &{&1["name"], &1})

      assert Map.keys(tools) |> Enum.sort() ==
               ["analyze_repositories", "check_packages", "get_analysis"]

      assert tools["check_packages"]["inputSchema"]["required"] == ["dependencies"]
      assert tools["check_packages"]["description"] =~ "pending"
      assert tools["analyze_repositories"]["inputSchema"]["required"] == ["urls"]
      assert tools["analyze_repositories"]["description"] =~ "get_analysis"
      assert tools["get_analysis"]["inputSchema"]["required"] == ["uuid"]
    end

    test "an unknown method is a JSON-RPC error, not a crash", %{key: key} do
      body = rpc(key, "resources/list")

      assert body["error"]["code"] == -32601
      assert body["id"] == 1
    end

    test "an unknown tool is an invalid-params error", %{key: key} do
      body = rpc(key, "tools/call", %{name: "rm_rf", arguments: %{}})

      assert body["error"]["code"] == -32602
    end

    test "params that are not an object are treated as none", %{key: key} do
      body = rpc(key, "initialize", ["2025-06-18"])

      assert body["result"]["protocolVersion"] == hd(Lei.Mcp.protocol_versions())
    end

    test "a JSON-RPC batch is refused: the protocol no longer has them", %{key: key} do
      conn =
        mcp([%{jsonrpc: "2.0", id: 1, method: "ping"}], [{"authorization", "Bearer " <> key}])

      assert conn.status == 400
      assert Poison.decode!(conn.resp_body)["error"]["code"] == -32600
    end

    test "there is no event stream to open", %{key: key} do
      for method <- [:get, :delete] do
        conn =
          conn(method, "/mcp")
          |> put_req_header("authorization", "Bearer " <> key)
          |> LeiService.Endpoint.call(@opts)

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "an unsupported protocol version header is refused", %{key: key} do
      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "ping"}, [
          {"authorization", "Bearer " <> key},
          {"mcp-protocol-version", "1999-01-01"}
        ])

      assert conn.status == 400
    end
  end

  describe "who may call it" do
    test "no credentials is a 401 that says how to authenticate" do
      conn = mcp(%{jsonrpc: "2.0", id: 1, method: "initialize"}, [])

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~r/^Bearer /
    end

    test "an invalid key is a 401 naming the token as the problem" do
      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "initialize"}, [
          {"authorization", "Bearer lei_notakey"}
        ])

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="invalid_token")
    end

    test "a key without the analyze scope is refused" do
      {_org, key} = org_with_key(["cache"])

      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "initialize"}, [
          {"authorization", "Bearer " <> key}
        ])

      assert conn.status == 403
    end

    test "a payment credential is not a way in: /mcp has no payment challenges" do
      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "initialize"}, [
          {"authorization", "Payment abc"}
        ])

      assert conn.status == 401
    end

    test "a browser page on another origin cannot drive it", %{key: key} do
      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "ping"}, [
          {"authorization", "Bearer " <> key},
          {"origin", "https://evil.example"}
        ])

      assert conn.status == 403
    end

    test "this service's own origin may", %{key: key} do
      origin = Application.get_env(:lei_service, :lei_base_url)

      conn =
        mcp(%{jsonrpc: "2.0", id: 1, method: "ping"}, [
          {"authorization", "Bearer " <> key},
          {"origin", origin}
        ])

      assert conn.status == 200
    end

    test "it shares the key's one allowance", %{key: key} do
      saved = Application.get_env(:lei_service, :rate_limits)
      Application.put_env(:lei_service, :rate_limits, Map.merge(saved, %{free: 2}))
      on_exit(fn -> Application.put_env(:lei_service, :rate_limits, saved) end)

      ping = %{jsonrpc: "2.0", id: 1, method: "ping"}
      auth = [{"authorization", "Bearer " <> key}]

      assert mcp(ping, auth).status == 200
      assert mcp(ping, auth).status == 200

      limited = mcp(ping, auth)
      assert limited.status == 429
      assert [_] = get_resp_header(limited, "retry-after")
    end
  end

  describe "check_packages" do
    test "a miss is queued, charged as the batch route charges, and reported pending",
         %{org: org, key: key} do
      result = call_tool(key, "check_packages", %{dependencies: [@dep]})

      refute result["isError"]
      structured = result["structuredContent"]
      assert [%{"status" => "pending"}] = structured["results"]
      assert structured["billing"]["cache_misses"] == 1

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Poison.decode!(text) == structured

      assert %{cache_misses: 1} = UsageTracker.get_current_usage(org.id)
    end

    test "asking again while it is pending is free", %{org: org, key: key} do
      call_tool(key, "check_packages", %{dependencies: [@dep]})
      result = call_tool(key, "check_packages", %{dependencies: [@dep]})

      assert [%{"status" => "pending"}] = result["structuredContent"]["results"]
      assert %{cache_hits: 0, cache_misses: 1} = UsageTracker.get_current_usage(org.id)
    end

    test "invalid arguments are a tool error the model can read, and nothing is charged",
         %{org: org, key: key} do
      result = call_tool(key, "check_packages", %{dependencies: [%{"package" => "x"}]})

      assert result["isError"]
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "ecosystem, package, and version"
      assert %{cache_misses: 0} = UsageTracker.get_current_usage(org.id)
    end

    test "arguments that are not an object are a tool error, not a crash", %{key: key} do
      result = call_tool(key, "check_packages", ["left-pad"])

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "dependencies"
    end

    test "an exhausted allowance is a tool error with where to upgrade, not a 402" do
      {org, key} = org_with_key(["analyze"], free_tier_analyses_limit: 1)
      {:ok, _} = UsageTracker.record_usage(org.id, nil, 0, 1)

      result = call_tool(key, "check_packages", %{dependencies: [@dep]})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "/signup?tier=pro"
      assert result["structuredContent"]["error"] == "free_tier_quota_exceeded"
      assert %{cache_misses: 1} = UsageTracker.get_current_usage(org.id)
    end

    test "a call is counted as remote MCP adoption", %{key: key} do
      before = adoption("mcp-remote")
      call_tool(key, "check_packages", %{dependencies: [@dep]})

      assert adoption("mcp-remote") == before + 1
    end
  end

  describe "analyze_repositories" do
    setup do
      # Queued, never run: Oban is :manual in tests. A short wait, so an
      # uncached repository times out into an incomplete job promptly.
      saved = {
        Application.get_env(:lei_service, :use_workers),
        Application.get_env(:lei_service, :default_cache_timeout)
      }

      Application.put_env(:lei_service, :use_workers, true)
      Application.put_env(:lei_service, :default_cache_timeout, 200)

      on_exit(fn ->
        {workers, timeout} = saved
        restore(:use_workers, workers)
        restore(:default_cache_timeout, timeout)
      end)
    end

    test "a cached repository is reported, with what it cost", %{org: org, key: key} do
      url = cached_url()
      result = call_tool(key, "analyze_repositories", %{urls: [url]})

      refute result["isError"]
      structured = result["structuredContent"]
      assert structured["state"] == "complete"
      assert [%{"data" => %{"repo" => ^url}}] = structured["report"]["repos"]
      assert %{"cache_hits" => 1, "cache_misses" => 0} = structured["billing"]

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Poison.decode!(text) == structured

      assert %{cache_hits: 1, cache_misses: 0} = UsageTracker.get_current_usage(org.id)
    end

    test "an uncached repository is charged once, and collected for free with get_analysis",
         %{org: org, key: key} do
      result = call_tool(key, "analyze_repositories", %{urls: [uncached_url()]})

      refute result["isError"]
      structured = result["structuredContent"]
      assert structured["state"] == "incomplete"
      assert is_binary(uuid = structured["uuid"])
      assert structured["next"] =~ "get_analysis"
      assert %{cache_misses: 1} = UsageTracker.get_current_usage(org.id)

      job = call_tool(key, "get_analysis", %{uuid: uuid})

      refute job["isError"]
      assert job["structuredContent"]["uuid"] == uuid
      assert job["structuredContent"]["state"] == "incomplete"
      assert job["structuredContent"]["next"] =~ "get_analysis"
      assert %{cache_hits: 0, cache_misses: 1} = UsageTracker.get_current_usage(org.id)
    end

    test "invalid URLs are a tool error, and nothing is charged", %{org: org, key: key} do
      result = call_tool(key, "analyze_repositories", %{urls: ["not a url"]})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "invalid URLs"
      assert %{cache_hits: 0, cache_misses: 0} = UsageTracker.get_current_usage(org.id)
    end

    test "arguments without a urls list are a tool error, not a crash", %{key: key} do
      result = call_tool(key, "analyze_repositories", ["https://github.com/a/b"])

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "urls"
    end

    test "an exhausted allowance is a tool error with where to upgrade, not a 402" do
      {org, key} = org_with_key(["analyze"], free_tier_analyses_limit: 1)
      {:ok, _} = UsageTracker.record_usage(org.id, nil, 0, 1)

      result = call_tool(key, "analyze_repositories", %{urls: [uncached_url()]})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "/signup?tier=pro"
      assert %{cache_misses: 1} = UsageTracker.get_current_usage(org.id)
    end

    test "a call is counted as remote MCP adoption", %{key: key} do
      before = adoption("mcp-remote")
      call_tool(key, "analyze_repositories", %{urls: [cached_url()]})

      assert adoption("mcp-remote") == before + 1
    end
  end

  describe "get_analysis" do
    test "an id that names no job is a tool error", %{key: key} do
      result = call_tool(key, "get_analysis", %{uuid: UUID.uuid4()})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "no job"
    end

    test "an id that is not a job id is refused before the datastore is asked", %{key: key} do
      result = call_tool(key, "get_analysis", %{uuid: "lei_request_log"})

      assert result["isError"]
    end
  end

  defp restore(key, nil), do: Application.delete_env(:lei_service, key)
  defp restore(key, value), do: Application.put_env(:lei_service, key, value)

  # Unique per call: the cache is shared state and not sandboxed.
  defp uncached_url,
    do: "https://github.com/kitplummer/mcp-uncached-#{System.unique_integer([:positive])}"

  defp cached_url do
    url = "https://github.com/kitplummer/mcp-cached-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    LeiService.Datastore.write_to_cache(url, %{
      data: %{repo: url},
      header: %{end_time: now, start_time: now, uuid: "mcp-cached"}
    })

    url
  end

  defp adoption(bucket) do
    {:ok, counts} = Lei.Adoption.window(1)
    Map.fetch!(counts, bucket)
  end
end
