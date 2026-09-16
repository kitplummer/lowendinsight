defmodule Lei.LowSeverityHardeningTest do
  @moduledoc """
  The three low-severity findings from the 2026-09-14 review.

  Each is narrow on its own; each is also the kind of gap that stops being
  narrow when something else changes around it.
  """
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, RateLimiter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    RateLimiter.clear()
    :ok
  end

  defp org_with_recovery do
    name = "recover-test-#{System.unique_integer([:positive])}"
    {:ok, org} = ApiKeys.create_org(name)
    {:ok, code} = ApiKeys.generate_recovery_code(org)
    {org, org.slug, code}
  end

  describe "a recovery code is spent once" do
    test "two simultaneous recoveries with the same code yield one admin key" do
      {_org, slug, code} = org_with_recovery()

      # Both read `used == false` before either wrote it, and both went on to
      # mint an admin key and rotate the code (security review, 2026-09-14).
      #
      # The sandbox lends one connection, so these interleave rather than run
      # truly in parallel: what this pins is that the code is spent once,
      # whoever asks. The UPDATE ... WHERE used = false is what makes that
      # true under real concurrency.
      parent = self()

      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Lei.Repo, parent, self())
            ApiKeys.recover_with_code(slug, code)
          end,
          max_concurrency: 2,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_recovery}, &1)) == 1
    end

    test "a spent code is refused afterwards" do
      {_org, slug, code} = org_with_recovery()
      assert {:ok, _key, _new_code} = ApiKeys.recover_with_code(slug, code)
      assert {:error, :invalid_recovery} = ApiKeys.recover_with_code(slug, code)
    end

    test "the rotated code works, and only once" do
      {_org, slug, code} = org_with_recovery()
      assert {:ok, _key, rotated} = ApiKeys.recover_with_code(slug, code)
      assert {:ok, _key2, _next} = ApiKeys.recover_with_code(slug, rotated)
      assert {:error, :invalid_recovery} = ApiKeys.recover_with_code(slug, rotated)
    end
  end

  describe "rate limit buckets are namespaced" do
    test "a key without a namespace is refused, loudly" do
      # Buckets share one table: acp:, payments:, auth:, try_it: and API keys.
      # An unnamespaced key can collide with another bucket's, and a collision
      # is invisible -- it just consumes someone else's allowance.
      assert_raise ArgumentError, fn -> RateLimiter.check("lei_abcd1234", "free") end
    end

    test "namespaced keys count separately" do
      assert {:ok, _} = RateLimiter.check("api:lei_abcd1234", "free")
      assert {:ok, remaining} = RateLimiter.check("acp:acp:1.2.3.4", "acp")
      assert is_integer(remaining)
    end

    test "every caller in the service passes a namespaced key" do
      sources =
        Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__)) ++
          Path.wildcard(Path.expand("../../../lei_service/lib/**/*.ex", __DIR__))

      calls =
        sources
        |> Enum.flat_map(fn file ->
          File.read!(file)
          |> then(&Regex.scan(~r/RateLimiter\.check\(\s*([^,]+),/, &1))
          |> Enum.map(fn [_, arg] -> {Path.basename(file), String.trim(arg)} end)
        end)

      assert calls != [], "no RateLimiter.check/2 calls found; this test checked nothing"

      unnamespaced =
        Enum.reject(calls, fn {_file, arg} ->
          String.starts_with?(arg, "\"") and String.contains?(arg, ":")
        end)

      assert unnamespaced == [], "these pass an unnamespaced bucket key: #{inspect(unnamespaced)}"
    end
  end

  describe "a settled challenge is answered again, not refused" do
    alias Lei.Payments.ChallengeStore

    test "fetch still returns a settled challenge, so a retry can succeed" do
      # The replay window in the review is mitigated by design, not by a time
      # limit: each rail refuses an expired challenge, and the ledger's unique
      # external_ref makes a second credit impossible. An agent whose response
      # was lost must be able to retry with the same credential and get a
      # receipt. Refusing it here would turn a dropped response into a payment
      # the agent cannot recover.
      {:ok, record} = settled_challenge()

      assert {:ok, _challenge, returned} = ChallengeStore.fetch(record.challenge_id)
      assert returned.settled_at != nil
    end

    test "an unknown challenge is refused rather than trusted" do
      assert {:error, :unknown_challenge} = ChallengeStore.fetch("chal_does_not_exist")
    end
  end

  defp unsettled_challenge do
    {:ok, org} = ApiKeys.create_org("challenge-test-#{System.unique_integer([:positive])}")

    challenge =
      Lei.Payments.Mpp.Challenge.new(
        realm: "lowendinsight.dev",
        request: %{"amount" => "1500", "currency" => "usd", "credits" => 15_000},
        expires: DateTime.add(DateTime.utc_now(), 300, :second)
      )

    {:ok, record} = Lei.Payments.ChallengeStore.put(challenge, org.id, Lei.Payments.Rails.Mpp)
    {:ok, record}
  end

  defp settled_challenge do
    {:ok, record} = unsettled_challenge()
    {:ok, settled} = Lei.Payments.ChallengeStore.mark_settled(record)
    {:ok, settled}
  end
end
