defmodule LowendinsightGet.RedisResilienceTest do
  @moduledoc """
  Exercises the Redis failure paths in Datastore and the readiness probe.

  Production evidence for these: with Redis unreachable, every Datastore
  function that matched only `{:ok, ...}` raised

      ** (CaseClauseError) no case clause matching:
         {:error, %Redix.ConnectionError{reason: :closed}}

  which crashed the trending job and any analysis that consulted the cache.
  Rather than mocking Redix, these tests point Datastore at a Redis that is
  genuinely not there, so the real error tuples flow through the real code.
  """
  use ExUnit.Case, async: false

  alias LowendinsightGet.Datastore

  @dead_conn :dead_redix_for_tests

  setup do
    # Port 1 is reserved and nothing listens on it, so every command fails
    # with a connection error rather than a timeout.
    {:ok, _pid} =
      Redix.start_link(
        host: "127.0.0.1",
        port: 1,
        name: @dead_conn,
        sync_connect: false,
        exit_on_disconnection: false,
        backoff_max: 100
      )

    previous = Application.get_env(:lowendinsight_get, :redix_name)
    Application.put_env(:lowendinsight_get, :redix_name, @dead_conn)

    on_exit(fn ->
      if previous do
        Application.put_env(:lowendinsight_get, :redix_name, previous)
      else
        Application.delete_env(:lowendinsight_get, :redix_name)
      end
    end)

    :ok
  end

  describe "reads degrade to a cache miss" do
    test "get_from_cache/2 returns a 3-tuple miss instead of raising" do
      assert {:error, _msg, :miss} =
               Datastore.get_from_cache("https://github.com/kitplummer/lowendinsight", 28)
    end

    test "get_from_cache_any_age/1 returns a 3-tuple miss instead of raising" do
      assert {:error, _msg, :miss} =
               Datastore.get_from_cache_any_age("https://github.com/kitplummer/lowendinsight")
    end

    test "in_cache?/1 reports false rather than raising" do
      refute Datastore.in_cache?("https://github.com/kitplummer/lowendinsight")
    end

    test "get_job/1 returns an error tuple" do
      assert {:error, _} = Datastore.get_job("some-uuid")
    end
  end

  describe "writes return the documented error tuple" do
    # The docstrings already promised "{:error, reason} if there is an error
    # writing to Redis"; the clause was simply never written.
    test "write_to_cache/2 returns {:error, reason}" do
      assert {:error, %Redix.ConnectionError{}} =
               Datastore.write_to_cache("https://github.com/kitplummer/lowendinsight", %{a: 1})
    end

    test "write_job/2 returns {:error, reason}" do
      assert {:error, %Redix.ConnectionError{}} = Datastore.write_job("uuid", %{a: 1})
    end

    test "write_event/1 returns {:error, reason}" do
      assert {:error, %Redix.ConnectionError{}} = Datastore.write_event(%{a: 1})
    end
  end

  describe "readiness reflects Redis" do
    test "reports redis error and overall degraded, not error" do
      health = Lei.Health.readiness()

      assert health.checks[:redis] == "error"
      assert health.checks[:database] == "ok"

      # Degraded, not error: the service still functions without the cache, so
      # it must not be pulled out of rotation.
      assert health.status == "degraded"
    end
  end
end
