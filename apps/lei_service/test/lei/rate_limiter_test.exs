defmodule Lei.RateLimiterTest do
  use ExUnit.Case, async: false

  setup do
    Lei.RateLimiter.clear()

    # These tests override :rate_limits. They previously deleted it afterwards
    # rather than restoring it, so any test running later saw the limiter fall
    # back to its hardcoded free-tier default -- which made Lei.Acp.RateLimitTest
    # pass or fail depending on the ExUnit seed. Restore on every exit path.
    original = Application.get_env(:lei_service, :rate_limits)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lei_service, :rate_limits)
        value -> Application.put_env(:lei_service, :rate_limits, value)
      end
    end)

    :ok
  end

  describe "per-bucket windows (#152)" do
    setup do
      windows = Application.get_env(:lei_service, :rate_limit_windows)

      on_exit(fn ->
        if windows,
          do: Application.put_env(:lei_service, :rate_limit_windows, windows),
          else: Application.delete_env(:lei_service, :rate_limit_windows)
      end)

      :ok
    end

    test "a bucket with its own window counts over that window, not the default minute" do
      Application.put_env(:lei_service, :rate_limits, %{free: 60, pro: 600, try_it: 1})
      Application.put_env(:lei_service, :rate_limit_windows, %{try_it: 3_600_000})

      assert {:ok, 0} = Lei.RateLimiter.check("test:hourly", "try_it")
      assert {:error, :rate_limited, retry_after} = Lei.RateLimiter.check("test:hourly", "try_it")

      # Retry is measured against the hour, not the minute.
      assert retry_after > 60_000
    end

    test "cleanup keeps what a longer window still counts" do
      # Cleanup ran on the default minute, so an hourly bucket's history was
      # erased every two minutes and its limit could never be reached.
      Application.put_env(:lei_service, :rate_limits, %{free: 60, pro: 600, try_it: 1})
      Application.put_env(:lei_service, :rate_limit_windows, %{try_it: 3_600_000})

      assert {:ok, 0} = Lei.RateLimiter.check("test:survives-cleanup", "try_it")

      # Age the entry past the default minute but well inside the hour.
      [{key, [ts]}] = :ets.lookup(:lei_rate_limiter, "test:survives-cleanup")
      :ets.insert(:lei_rate_limiter, {key, [ts - 120_000]})

      send(Lei.RateLimiter, :cleanup)
      :sys.get_state(Lei.RateLimiter)

      assert {:error, :rate_limited, _} = Lei.RateLimiter.check("test:survives-cleanup", "try_it")
    end
  end

  test "allows requests under limit" do
    assert {:ok, _remaining} = Lei.RateLimiter.check("test:test-key", "free")
  end

  test "decrements remaining count" do
    {:ok, first} = Lei.RateLimiter.check("test:counter-key", "free")
    {:ok, second} = Lei.RateLimiter.check("test:counter-key", "free")
    assert second == first - 1
  end

  test "blocks when limit exceeded" do
    Application.put_env(:lei_service, :rate_limits, %{free: 3, pro: 600})

    assert {:ok, 2} = Lei.RateLimiter.check("test:limited-key", "free")
    assert {:ok, 1} = Lei.RateLimiter.check("test:limited-key", "free")
    assert {:ok, 0} = Lei.RateLimiter.check("test:limited-key", "free")
    assert {:error, :rate_limited, _retry} = Lei.RateLimiter.check("test:limited-key", "free")
  end

  test "pro tier gets higher limit" do
    Application.put_env(:lei_service, :rate_limits, %{free: 2, pro: 5})

    Lei.RateLimiter.check("test:free-key", "free")
    Lei.RateLimiter.check("test:free-key", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("test:free-key", "free")

    Lei.RateLimiter.check("test:pro-key", "pro")
    Lei.RateLimiter.check("test:pro-key", "pro")
    assert {:ok, _} = Lei.RateLimiter.check("test:pro-key", "pro")
  end

  test "different keys are independent" do
    Application.put_env(:lei_service, :rate_limits, %{free: 1, pro: 600})

    assert {:ok, 0} = Lei.RateLimiter.check("test:key-a", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("test:key-a", "free")
    assert {:ok, 0} = Lei.RateLimiter.check("test:key-b", "free")
  end

  test "reset clears state for a key" do
    Application.put_env(:lei_service, :rate_limits, %{free: 1, pro: 600})

    assert {:ok, 0} = Lei.RateLimiter.check("test:reset-key", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("test:reset-key", "free")
    Lei.RateLimiter.reset("test:reset-key")
    assert {:ok, 0} = Lei.RateLimiter.check("test:reset-key", "free")
  end

  test "returns retry_after when rate limited" do
    Application.put_env(:lei_service, :rate_limits, %{free: 1, pro: 600})

    Lei.RateLimiter.check("test:retry-key", "free")
    assert {:error, :rate_limited, retry_after} = Lei.RateLimiter.check("test:retry-key", "free")
    assert is_integer(retry_after)
    assert retry_after >= 0
  end
end
