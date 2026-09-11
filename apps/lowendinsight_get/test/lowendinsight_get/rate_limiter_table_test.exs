defmodule LowendinsightGet.Plugs.RateLimiterTableTest do
  @moduledoc """
  The rate limiter created its ETS table in `init/1`. Plug.Builder resolves
  `init/1` at compile time, so the table belonged to the compiler process and
  did not exist at runtime. Every authenticated POST /v1/analyze then raised

      ArgumentError: the table identifier does not refer to an existing ETS table

  Tests did not catch it because Plug uses runtime init in this environment, so
  the table happens to exist. These delete it first, reproducing the production
  condition rather than relying on the environment's default.
  """
  use ExUnit.Case, async: false

  alias LowendinsightGet.Plugs.RateLimiter

  @table :lowendinsight_get_analyze_rl

  setup do
    on_exit(fn -> RateLimiter.init_table() end)
    :ok
  end

  defp delete_table do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end
  end

  test "init_table/0 creates the table" do
    delete_table()
    assert :ets.whereis(@table) == :undefined

    assert :ok = RateLimiter.init_table()
    refute :ets.whereis(@table) == :undefined
  end

  test "init_table/0 is idempotent" do
    RateLimiter.init_table()
    assert :ok = RateLimiter.init_table()
  end

  test "a rate-limited request does not raise when the table is missing" do
    delete_table()

    api_key = %{key_prefix: "lei_test", org: %{tier: "free"}}

    conn =
      Plug.Test.conn(:post, "/v1/analyze", "{}")
      |> Plug.Conn.assign(:current_api_key, api_key)

    # The regression: this raised instead of rate limiting.
    result = RateLimiter.call(conn, [])

    refute result.halted, "a first request should not be rate limited"
  end

  test "init/1 no longer creates the table" do
    delete_table()

    # Plug resolves init/1 at compile time, so it must not have side effects
    # the runtime depends on.
    RateLimiter.init([])

    assert :ets.whereis(@table) == :undefined,
           "init/1 must not create the table -- it runs at compile time"
  end
end
