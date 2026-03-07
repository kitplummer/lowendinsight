defmodule Lei.RateLimiterTest do
  use ExUnit.Case, async: false

  setup do
    Lei.RateLimiter.clear()
    :ok
  end

  test "allows requests under limit" do
    assert {:ok, _remaining} = Lei.RateLimiter.check("test-key", "free")
  end

  test "decrements remaining count" do
    {:ok, first} = Lei.RateLimiter.check("counter-key", "free")
    {:ok, second} = Lei.RateLimiter.check("counter-key", "free")
    assert second == first - 1
  end

  test "blocks when limit exceeded" do
    # Use a tiny custom limit
    Application.put_env(:lowendinsight, :rate_limits, %{free: 3, pro: 600})

    assert {:ok, 2} = Lei.RateLimiter.check("limited-key", "free")
    assert {:ok, 1} = Lei.RateLimiter.check("limited-key", "free")
    assert {:ok, 0} = Lei.RateLimiter.check("limited-key", "free")
    assert {:error, :rate_limited, _retry} = Lei.RateLimiter.check("limited-key", "free")

    Application.delete_env(:lowendinsight, :rate_limits)
  end

  test "pro tier gets higher limit" do
    Application.put_env(:lowendinsight, :rate_limits, %{free: 2, pro: 5})

    # Free gets blocked after 2
    Lei.RateLimiter.check("free-key", "free")
    Lei.RateLimiter.check("free-key", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("free-key", "free")

    # Pro still has room
    Lei.RateLimiter.check("pro-key", "pro")
    Lei.RateLimiter.check("pro-key", "pro")
    assert {:ok, _} = Lei.RateLimiter.check("pro-key", "pro")

    Application.delete_env(:lowendinsight, :rate_limits)
  end

  test "different keys are independent" do
    Application.put_env(:lowendinsight, :rate_limits, %{free: 1, pro: 600})

    assert {:ok, 0} = Lei.RateLimiter.check("key-a", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("key-a", "free")
    # Different key still works
    assert {:ok, 0} = Lei.RateLimiter.check("key-b", "free")

    Application.delete_env(:lowendinsight, :rate_limits)
  end

  test "reset clears state for a key" do
    Application.put_env(:lowendinsight, :rate_limits, %{free: 1, pro: 600})

    assert {:ok, 0} = Lei.RateLimiter.check("reset-key", "free")
    assert {:error, :rate_limited, _} = Lei.RateLimiter.check("reset-key", "free")
    Lei.RateLimiter.reset("reset-key")
    assert {:ok, 0} = Lei.RateLimiter.check("reset-key", "free")

    Application.delete_env(:lowendinsight, :rate_limits)
  end

  test "returns retry_after when rate limited" do
    Application.put_env(:lowendinsight, :rate_limits, %{free: 1, pro: 600})

    Lei.RateLimiter.check("retry-key", "free")
    assert {:error, :rate_limited, retry_after} = Lei.RateLimiter.check("retry-key", "free")
    assert is_integer(retry_after)
    assert retry_after >= 0

    Application.delete_env(:lowendinsight, :rate_limits)
  end
end
