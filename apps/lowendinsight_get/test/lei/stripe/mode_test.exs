defmodule Lei.Stripe.ModeTest do
  @moduledoc """
  The mode is read from the key, and a half-flip is refused at boot where it
  can be seen without the network (#137).
  """
  use ExUnit.Case, async: true

  alias Lei.Stripe.Mode

  # Built at runtime so no string in this file looks like a real key to a
  # secret scanner, and so none of them is one.
  defp key(prefix), do: prefix <> String.duplicate("x", 24)

  describe "of/1" do
    test "reads the mode from every secret and restricted key prefix" do
      assert Mode.of(key("sk_live_")) == :live
      assert Mode.of(key("rk_live_")) == :live
      assert Mode.of(key("sk_test_")) == :test
      assert Mode.of(key("rk_test_")) == :test
    end

    test "no key is unconfigured" do
      assert Mode.of(nil) == :unconfigured
      assert Mode.of("") == :unconfigured
    end

    test "a key that is present but not a secret key is malformed, not unconfigured" do
      # The usual mistakes: publishable key, webhook secret, a truncated paste.
      assert Mode.of(key("pk_live_")) == :malformed
      assert Mode.of(key("whsec_")) == :malformed
      assert Mode.of("sk_") == :malformed
      assert Mode.of(" " <> key("sk_live_")) == :malformed
    end

    test "a prefix only counts at the start" do
      assert Mode.of("x" <> key("sk_live_")) == :malformed
      assert Mode.of(key("sk_") <> "_live_") == :malformed
    end
  end

  describe "validate!/1" do
    test "a live key boots in production" do
      assert :ok =
               Mode.validate!(
                 key: key("sk_live_"),
                 webhook_secret: key("whsec_"),
                 profile: nil,
                 deploy_env: "production"
               )
    end

    test "a test key boots everywhere, production included" do
      for env <- ["production", "staging", nil] do
        assert :ok =
                 Mode.validate!(
                   key: key("sk_test_"),
                   webhook_secret: key("whsec_"),
                   deploy_env: env
                 )
      end
    end

    test "no Stripe configuration at all boots" do
      assert :ok = Mode.validate!(key: nil, webhook_secret: nil, deploy_env: nil)
    end

    test "a live key outside production is refused, naming both halves" do
      for env <- [nil, "staging", "Production", ""] do
        error =
          assert_raise ArgumentError, fn ->
            Mode.validate!(
              key: key("rk_live_"),
              webhook_secret: nil,
              profile: nil,
              deploy_env: env
            )
          end

        assert error.message =~ "live Stripe key"
        assert error.message =~ "LEI_DEPLOY_ENV is #{inspect(env)}"
      end
    end

    test "a malformed key is refused in production too" do
      error =
        assert_raise ArgumentError, fn ->
          Mode.validate!(key: key("pk_live_"), webhook_secret: nil, deploy_env: "production")
        end

      assert error.message =~ ~s(begins "pk_live_")
    end

    test "a malformed webhook secret is refused" do
      error =
        assert_raise ArgumentError, fn ->
          Mode.validate!(key: key("sk_test_"), webhook_secret: key("sk_test_"), deploy_env: nil)
        end

      assert error.message =~ "STRIPE_WEBHOOK_SECRET"
      assert error.message =~ ~s(begins "sk_test_")
    end

    test "a profile must be in the key's mode" do
      error =
        assert_raise ArgumentError, fn ->
          Mode.validate!(
            key: key("sk_live_"),
            profile: "profile_test_abc",
            deploy_env: "production"
          )
        end

      assert error.message =~ "test profile"
      assert error.message =~ "live key"

      assert_raise ArgumentError, ~r/live profile/, fn ->
        Mode.validate!(key: key("rk_test_"), profile: "profile_abc", deploy_env: nil)
      end

      assert :ok =
               Mode.validate!(key: key("sk_test_"), profile: "profile_test_abc", deploy_env: nil)

      assert :ok =
               Mode.validate!(
                 key: key("sk_live_"),
                 profile: "profile_abc",
                 deploy_env: "production"
               )
    end

    test "a malformed profile is refused" do
      assert_raise ArgumentError, ~r/not a Stripe profile ID/, fn ->
        Mode.validate!(key: key("sk_test_"), profile: "acct_123", deploy_env: nil)
      end
    end

    test "refusal messages never carry the secret part" do
      secret = "sk_live_" <> "SENSITIVEPART123"

      error =
        assert_raise ArgumentError, fn ->
          Mode.validate!(key: secret, webhook_secret: nil, deploy_env: nil)
        end

      refute error.message =~ "SENSITIVEPART"

      error =
        assert_raise ArgumentError, fn ->
          Mode.validate!(key: "pk_live_SENSITIVEPART123", webhook_secret: nil, deploy_env: nil)
        end

      refute error.message =~ "SENSITIVEPART"
    end
  end
end
