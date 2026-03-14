defmodule Lei.Web.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Web.Plugs.RateLimiter

  @opts RateLimiter.init(limit: 3)

  setup do
    RateLimiter.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check/2 unit tests
  # ---------------------------------------------------------------------------

  describe "check/2" do
    test "allows first request and returns remaining count" do
      assert {:ok, 2} = RateLimiter.check("test-key", 3)
    end

    test "decrements remaining on each call" do
      assert {:ok, 2} = RateLimiter.check("dec-key", 3)
      assert {:ok, 1} = RateLimiter.check("dec-key", 3)
      assert {:ok, 0} = RateLimiter.check("dec-key", 3)
    end

    test "blocks once limit is exhausted" do
      RateLimiter.check("block-key", 3)
      RateLimiter.check("block-key", 3)
      RateLimiter.check("block-key", 3)
      assert {:error, :rate_limited, retry_after} = RateLimiter.check("block-key", 3)
      assert is_integer(retry_after)
      assert retry_after >= 0
    end

    test "different keys are tracked independently" do
      RateLimiter.check("key-a", 1)
      assert {:error, :rate_limited, _} = RateLimiter.check("key-a", 1)
      # key-b is unaffected
      assert {:ok, _} = RateLimiter.check("key-b", 1)
    end

    test "reset/1 clears state for a key" do
      RateLimiter.check("reset-key", 1)
      assert {:error, :rate_limited, _} = RateLimiter.check("reset-key", 1)
      RateLimiter.reset("reset-key")
      assert {:ok, _} = RateLimiter.check("reset-key", 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Plug call/2 tests
  # ---------------------------------------------------------------------------

  describe "call/2 — /v1/analyze path" do
    test "passes requests that are within the limit" do
      conn =
        conn(:post, "/v1/analyze/batch", "")
        |> RateLimiter.call(@opts)

      refute conn.halted
      refute conn.status == 429
    end

    test "returns 429 when limit is exceeded" do
      # Exhaust the limit (3 requests)
      for _ <- 1..3, do: conn(:post, "/v1/analyze/batch", "") |> RateLimiter.call(@opts)

      conn =
        conn(:post, "/v1/analyze/batch", "")
        |> RateLimiter.call(@opts)

      assert conn.halted
      assert conn.status == 429
    end

    test "429 response includes Retry-After header" do
      for _ <- 1..3, do: conn(:post, "/v1/analyze/batch", "") |> RateLimiter.call(@opts)

      conn =
        conn(:post, "/v1/analyze/batch", "")
        |> RateLimiter.call(@opts)

      [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "429 response body contains error and retry_after fields" do
      for _ <- 1..3, do: conn(:post, "/v1/analyze/batch", "") |> RateLimiter.call(@opts)

      conn =
        conn(:post, "/v1/analyze/batch", "")
        |> RateLimiter.call(@opts)

      body = Poison.decode!(conn.resp_body)
      assert body["error"] == "rate limit exceeded"
      assert is_integer(body["retry_after"])
    end

    test "uses api key prefix when current_api_key is assigned" do
      api_key = %{key_prefix: "lei_test"}

      conn_a =
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, api_key)
        |> RateLimiter.call(@opts)

      refute conn_a.halted

      # Exhaust limit for this api key
      for _ <- 1..2 do
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, api_key)
        |> RateLimiter.call(@opts)
      end

      conn_over =
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, api_key)
        |> RateLimiter.call(@opts)

      assert conn_over.halted
      assert conn_over.status == 429
    end

    test "different api keys have independent buckets" do
      key_a = %{key_prefix: "lei_aaa"}
      key_b = %{key_prefix: "lei_bbb"}

      # Exhaust key_a
      for _ <- 1..3 do
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, key_a)
        |> RateLimiter.call(@opts)
      end

      blocked =
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, key_a)
        |> RateLimiter.call(@opts)

      assert blocked.halted

      # key_b is still fine
      allowed =
        conn(:post, "/v1/analyze/batch", "")
        |> assign(:current_api_key, key_b)
        |> RateLimiter.call(@opts)

      refute allowed.halted
    end
  end

  # ---------------------------------------------------------------------------
  # Plug call/2 tests — non-analyze paths
  # ---------------------------------------------------------------------------

  describe "call/2 — non-analyze paths" do
    test "does not rate-limit /v1/health" do
      for _ <- 1..10 do
        conn = conn(:get, "/v1/health", "") |> RateLimiter.call(@opts)
        refute conn.halted
      end
    end

    test "does not rate-limit /healthz" do
      for _ <- 1..10 do
        conn = conn(:get, "/healthz", "") |> RateLimiter.call(@opts)
        refute conn.halted
      end
    end

    test "passes through already-halted connections" do
      halted_conn =
        conn(:post, "/v1/analyze/batch", "")
        |> halt()

      result = RateLimiter.call(halted_conn, @opts)
      assert result.halted
      # status was not set by the plug (it's nil, not 429)
      refute result.status == 429
    end
  end
end
