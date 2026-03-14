defmodule LowendinsightGet.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias LowendinsightGet.Plugs.RateLimiter

  @opts RateLimiter.init([])

  # Minimal API key struct with fields the plug reads
  defp fake_api_key(prefix \\ "test_prefix_abc") do
    %{key_prefix: prefix}
  end

  defp conn_with_key(prefix \\ "test_prefix_abc") do
    conn(:post, "/v1/analyze", %{urls: ["https://github.com/example/repo"]})
    |> assign(:current_api_key, fake_api_key(prefix))
  end

  defp conn_without_key do
    conn(:post, "/v1/analyze", %{urls: ["https://github.com/example/repo"]})
  end

  setup do
    # Ensure the ETS table exists (it's owned per-process; re-init if needed)
    RateLimiter.init([])
    RateLimiter.clear()
    :ok
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert RateLimiter.init([]) == []
      assert RateLimiter.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2 — non-matching routes" do
    test "passes through GET /v1/analyze/:uuid unchanged" do
      conn = conn(:get, "/v1/analyze/some-uuid") |> assign(:current_api_key, fake_api_key())
      result = RateLimiter.call(conn, @opts)
      refute result.halted
    end

    test "passes through POST /v1/analyze/sbom unchanged" do
      conn = conn(:post, "/v1/analyze/sbom", %{}) |> assign(:current_api_key, fake_api_key())
      result = RateLimiter.call(conn, @opts)
      refute result.halted
    end

    test "passes through POST /v1/analyze/batch unchanged" do
      conn = conn(:post, "/v1/analyze/batch", %{}) |> assign(:current_api_key, fake_api_key())
      result = RateLimiter.call(conn, @opts)
      refute result.halted
    end

    test "passes through unrelated paths unchanged" do
      conn = conn(:get, "/v1/health") |> assign(:current_api_key, fake_api_key())
      result = RateLimiter.call(conn, @opts)
      refute result.halted
    end
  end

  describe "call/2 — POST /v1/analyze without API key" do
    test "allows request when no API key is set (JWT auth)" do
      conn = conn_without_key()
      result = RateLimiter.call(conn, @opts)
      refute result.halted
    end
  end

  describe "call/2 — POST /v1/analyze with API key" do
    test "allows request under the limit and sets x-ratelimit-remaining" do
      conn = conn_with_key()
      result = RateLimiter.call(conn, @opts)
      refute result.halted
      [remaining] = get_resp_header(result, "x-ratelimit-remaining")
      assert String.to_integer(remaining) == 9
    end

    test "tracks remaining count correctly across requests" do
      prefix = "track_remaining"
      Enum.each(1..5, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      conn = conn_with_key(prefix)
      result = RateLimiter.call(conn, @opts)
      [remaining] = get_resp_header(result, "x-ratelimit-remaining")
      assert String.to_integer(remaining) == 4
    end

    test "allows exactly 10 requests" do
      prefix = "allow_10"

      results =
        Enum.map(1..10, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      assert Enum.all?(results, &(not &1.halted))
    end

    test "blocks the 11th request with 429" do
      prefix = "block_11"
      Enum.each(1..10, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      conn = conn_with_key(prefix)
      result = RateLimiter.call(conn, @opts)

      assert result.halted
      assert result.status == 429
      body = Poison.decode!(result.resp_body)
      assert body["error"] == "rate limit exceeded"
      assert is_integer(body["retry_after"])
      assert body["retry_after"] >= 1
    end

    test "429 response includes retry-after header" do
      prefix = "retry_after_header"
      Enum.each(1..10, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      result = RateLimiter.call(conn_with_key(prefix), @opts)

      [retry_after] = get_resp_header(result, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "different API key prefixes are rate limited independently" do
      prefix_a = "independent_a"
      prefix_b = "independent_b"
      Enum.each(1..10, fn _ -> RateLimiter.call(conn_with_key(prefix_a), @opts) end)

      # prefix_a is exhausted, prefix_b should still work
      result_b = RateLimiter.call(conn_with_key(prefix_b), @opts)
      refute result_b.halted

      # prefix_a is exhausted
      result_a = RateLimiter.call(conn_with_key(prefix_a), @opts)
      assert result_a.halted
      assert result_a.status == 429
    end

    test "reset/1 clears limit for a specific key" do
      prefix = "reset_test"
      Enum.each(1..10, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      # Should be blocked
      result = RateLimiter.call(conn_with_key(prefix), @opts)
      assert result.halted

      RateLimiter.reset(prefix)

      # Should be allowed again
      result = RateLimiter.call(conn_with_key(prefix), @opts)
      refute result.halted
    end
  end

  describe "configurable limit" do
    test "respects :analyze_rate_limit application env" do
      Application.put_env(:lowendinsight_get, :analyze_rate_limit, 3)
      RateLimiter.clear()
      prefix = "config_limit"

      Enum.each(1..3, fn _ -> RateLimiter.call(conn_with_key(prefix), @opts) end)

      result = RateLimiter.call(conn_with_key(prefix), @opts)
      assert result.halted
      assert result.status == 429
    after
      Application.delete_env(:lowendinsight_get, :analyze_rate_limit)
    end
  end
end
