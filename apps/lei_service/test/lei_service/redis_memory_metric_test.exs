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

  describe "the headroom check, run rather than read" do
    # `scripts/check-cache-headroom.sh` exists because the first version of this
    # was inline in monitor.yml, guarded by tests that asserted strings were
    # present in the YAML. Two mutations against the shell logic came back
    # **unguarded**: changing `[ "$MAX" = "0" ]` to `[ "$MAX" = "-1" ]` leaves
    # every asserted string in place. Text presence cannot catch behaviour,
    # which is the failure this repository is documented around.
    #
    # So the logic moved to a script and these drive it with metrics on stdin.
    @script Path.expand("../../../../scripts/check-cache-headroom.sh", __DIR__)

    defp check(metrics, env \\ []) do
      path = Path.join(System.tmp_dir!(), "headroom-#{System.unique_integer([:positive])}")
      File.write!(path, metrics)
      on_exit(fn -> File.rm_rf(path) end)

      {out, status} =
        System.cmd("bash", ["-c", "#{@script} < #{path}"],
          env: env,
          stderr_to_stdout: true
        )

      {status, out}
    end

    @healthy """
    lei_redis_memory_readable 1
    lei_redis_memory_bytes{type="used"} 7490
    lei_redis_maxmemory_bytes 1073741824
    lei_redis_maxmemory_policy{policy="optimistic-volatile"} 1
    """

    test "a cache with room, on the expected policy, passes" do
      assert {0, _out} = check(@healthy)
    end

    test "a cache near its budget fails" do
      # 912680550 of 1073741824 is 85%.
      near = String.replace(@healthy, "7490", "912680550")

      assert {1, out} = check(near)
      assert out =~ "of its"
      assert out =~ "dropped, silently"
    end

    test "an unlimited budget fails rather than reading as endless headroom" do
      # 0 is Redis's own way of saying unlimited, and it is what the operations
      # notes claimed production ran. Treating it as room is how an unbounded
      # cache stays green until the machine runs out.
      unlimited =
        String.replace(
          @healthy,
          "lei_redis_maxmemory_bytes 1073741824",
          "lei_redis_maxmemory_bytes 0"
        )

      assert {1, out} = check(unlimited)
      assert out =~ "maxmemory is 0"
    end

    test "a silently changed eviction policy fails" do
      # Which policy is in force decides which failure happens at the ceiling.
      # It arrived once as a provider default; it must not change unnoticed
      # twice (ADR-008).
      changed = String.replace(@healthy, "optimistic-volatile", "noeviction")

      assert {1, out} = check(changed)
      assert out =~ "Eviction policy is 'noeviction'"
    end

    test "a deliberate policy change can be declared" do
      changed = String.replace(@healthy, "optimistic-volatile", "allkeys-lru")

      assert {0, _} = check(changed, [{"EXPECTED_POLICY", "allkeys-lru"}])
    end

    test "an unreadable cache fails rather than being skipped" do
      assert {1, out} = check("lei_redis_memory_readable 0\n")
      assert out =~ "headroom cannot be checked"
    end

    test "an absent metric family fails rather than passing" do
      # An old release publishes none of these. Absence must not read as health.
      assert {1, out} = check("beam_memory_bytes{type=\"total\"} 1\n")
      assert out =~ "not readable"
    end

    test "the threshold is configurable" do
      near = String.replace(@healthy, "7490", "912680550")

      assert {0, _} = check(near, [{"WARN_PCT", "90"}])
      assert {1, _} = check(near, [{"WARN_PCT", "80"}])
    end

    test "monitor.yml actually calls it" do
      # A script nothing invokes is not a check.
      monitor = File.read!(Path.expand("../../../../.github/workflows/monitor.yml", __DIR__))

      assert monitor =~ "scripts/check-cache-headroom.sh",
             "the headroom check is not wired into the monitor"
    end
  end
end
