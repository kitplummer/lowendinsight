defmodule Lei.Stripe.ModeVisibilityTest do
  @moduledoc """
  The running mode is visible to monitoring and a human, and the boot refuses a
  half-flip (#137). Changes application env, so not async.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    saved =
      for k <- [:stripe_secret_key, :stripe_webhook_secret, :stripe_profile_id, :deploy_env],
          do: {k, Application.fetch_env(:lei_service, k)}

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:lei_service, k, value)
          :error -> Application.delete_env(:lei_service, k)
        end
      end
    end)

    :ok
  end

  defp put_key(prefix),
    do: Application.put_env(:lei_service, :stripe_secret_key, prefix <> String.duplicate("x", 24))

  defp readyz do
    conn = conn(:get, "/readyz") |> Lei.Web.Router.call(@opts)
    Poison.decode!(conn.resp_body)
  end

  test "/readyz reports the mode the key is in" do
    put_key("sk_test_")
    assert readyz()["stripe_mode"] == "test"

    put_key("rk_live_")
    assert readyz()["stripe_mode"] == "live"

    Application.delete_env(:lei_service, :stripe_secret_key)
    assert readyz()["stripe_mode"] == "unconfigured"
  end

  test "/readyz carries the object check" do
    assert Map.has_key?(readyz()["checks"], "stripe")
  end

  test "/metrics reports the mode as exactly one series" do
    put_key("sk_live_")
    output = Lei.Metrics.collect()
    assert output =~ ~s(lei_stripe_mode{mode="live"} 1)
    assert length(Regex.scan(~r/^lei_stripe_mode\{/m, output)) == 1

    put_key("sk_test_")
    assert Lei.Metrics.collect() =~ ~s(lei_stripe_mode{mode="test"} 1)
  end

  describe "boot checks" do
    test "pass with the test configuration" do
      assert :ok = Lei.Boot.checks!()
    end

    test "refuse a live key when not deployed to production" do
      put_key("sk_live_")
      Application.put_env(:lei_service, :deploy_env, "staging")
      assert_raise ArgumentError, ~r/live Stripe key/, &Lei.Boot.checks!/0
    end

    test "refuse a sandbox profile beside a live key" do
      put_key("sk_live_")
      Application.put_env(:lei_service, :deploy_env, "production")
      Application.put_env(:lei_service, :stripe_profile_id, "profile_test_lei")
      assert_raise ArgumentError, ~r/STRIPE_PROFILE_ID/, &Lei.Boot.checks!/0
    end

    test "accept a live key when deployed to production" do
      put_key("sk_live_")
      Application.put_env(:lei_service, :stripe_profile_id, "profile_lei")
      Application.put_env(:lei_service, :deploy_env, "production")
      assert :ok = Lei.Boot.checks!()
    end
  end
end
