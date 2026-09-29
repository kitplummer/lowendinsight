defmodule LeiService.RedisMemoryMetricTest do
  @moduledoc """
  The corpus lives in memory, so memory is the ceiling on the corpus.

  With `maxmemory` unlimited and `maxmemory_policy` `noeviction`, that ceiling
  arrives as refused *writes* while reads keep working: analyses still succeed,
  nothing caches, every request becomes a full clone at miss price, and each
  request individually looks fine. Nothing could see it coming (ADR-008).

  The failure this guards is the obvious one — that an unreadable Redis reports
  as an empty one. "0 bytes used" reads as plenty of headroom and is
  indistinguishable from Redis not being there at all.
  """
  use ExUnit.Case, async: false

  alias LeiService.Datastore

  describe "when Redis answers" do
    test "memory_info reports what Redis says about itself" do
      assert {:ok, info} = Datastore.memory_info()

      assert is_integer(info.used_bytes) and info.used_bytes > 0
      assert is_binary(info.maxmemory_policy)

      # 0 is Redis's own way of saying unlimited, so this is an integer check
      # rather than a positive one.
      assert is_integer(info.maxmemory_bytes)
    end

    test "a policy name is not cast to a number" do
      # INFO is `field:value` and most values are numeric. A parser that cast
      # everything would turn the policy into a string anyway, but one that cast
      # nothing would make the byte counts strings and the gauges unusable.
      assert {:ok, info} = Datastore.memory_info()

      refute is_number(info.maxmemory_policy)
      assert is_number(info.used_bytes)
    end

    test "the gauges are published" do
      metrics = Lei.Metrics.collect()

      assert metrics =~ "lei_redis_memory_readable 1"
      assert metrics =~ ~r/lei_redis_memory_bytes\{type="used"\} \d+/
      assert metrics =~ ~r/lei_redis_maxmemory_bytes \d+/
      assert metrics =~ ~r/lei_redis_maxmemory_policy\{policy="[a-z-]+"\} 1/
    end

    test "the eviction policy is published, because changing it changes the failure" do
      # noeviction refuses writes at the ceiling; an eviction policy would
      # instead silently drop other customers' entries. Both are defensible and
      # they fail completely differently, so which one is in force has to be
      # visible rather than assumed.
      metrics = Lei.Metrics.collect()

      assert metrics =~ "lei_redis_maxmemory_policy{policy="
    end
  end

  describe "when Redis does not answer" do
    @dead :dead_redix_for_memory_metric

    setup do
      # Port 1 is reserved, so every command fails with a connection error.
      {:ok, _} =
        Redix.start_link(
          host: "127.0.0.1",
          port: 1,
          name: @dead,
          sync_connect: false,
          exit_on_disconnection: false,
          backoff_max: 100
        )

      previous = Application.get_env(:lei_service, :redix_name)
      Application.put_env(:lei_service, :redix_name, @dead)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:lei_service, :redix_name, previous),
          else: Application.delete_env(:lei_service, :redix_name)
      end)

      :ok
    end

    test "memory_info returns an error rather than zeros" do
      assert {:error, _} = Datastore.memory_info()
    end

    test "no byte gauge is published at all" do
      # The one that matters. A `lei_redis_memory_bytes{type="used"} 0` would
      # read as a cache with all the headroom in the world, and would look
      # identical to a healthy Redis holding nothing.
      metrics = Lei.Metrics.collect()

      refute metrics =~ "lei_redis_memory_bytes",
             "an unreadable Redis published a memory figure"

      refute metrics =~ "lei_redis_maxmemory_bytes"
    end

    test "the readable gauge is still published, and says 0" do
      # Emitted whether or not Redis answered: an absent metric family cannot be
      # told apart from a scrape that failed, so "we could not read it" has to be
      # a value rather than a silence.
      metrics = Lei.Metrics.collect()

      assert metrics =~ "lei_redis_memory_readable 0"
    end

    test "the rest of the endpoint still renders" do
      # A metrics endpoint that raises when Redis is down takes out every other
      # signal at exactly the moment they are wanted.
      metrics = Lei.Metrics.collect()

      assert metrics =~ "beam_memory_bytes"
      assert metrics =~ "lei_billing_mode"
    end
  end
end
