defmodule Lei.Stripe.Mode do
  @moduledoc """
  Whether Stripe is in test or live mode -- derived from the key, never declared.

  ## Only the key knows

  Test and live are separate object spaces: a live key cannot see a test price
  and a test key cannot see a live one. Of everything this app is configured
  with, only the API key says which space it belongs to -- `sk_test_` /
  `sk_live_`, `rk_test_` / `rk_live_`. Price IDs, product IDs and webhook
  signing secrets carry no marker; a test price and a live price look identical.

  So there is no `STRIPE_MODE` setting. A flag beside the key is two sources of
  truth, and two sources of truth drift.

  ## What is caught where

    * **At boot, no network** (`validate!/1`): a malformed key, a malformed
      webhook secret, and a live key outside production.
    * **After boot, over the network** (`Lei.Stripe.ObjectCheck`): whether the
      configured price IDs exist in the key's mode. That needs Stripe, and a
      boot that depends on Stripe turns a Stripe outage into ours.
    * **Nowhere**: whether the webhook secret matches the endpoint. It is a
      signing secret, not an object, and no API verifies it. A real signed
      delivery verifying is the only proof; `Lei.WebhookStats` counts those.
  """

  @live_prefixes ["sk_live_", "rk_live_"]
  @test_prefixes ["sk_test_", "rk_test_"]

  @doc """
  The mode a secret key belongs to: `:live`, `:test`, `:unconfigured` for no key,
  or `:malformed` for a key that is present but carries neither prefix.

  Malformed is kept distinct from unconfigured on purpose. A publishable key or
  a webhook secret pasted into the key variable is a mistake someone made while
  trying to configure Stripe; reading it as "billing is off" would hide it.
  """
  def of(nil), do: :unconfigured

  def of(key) when is_binary(key) do
    cond do
      key == "" -> :unconfigured
      String.starts_with?(key, @live_prefixes) -> :live
      String.starts_with?(key, @test_prefixes) -> :test
      true -> :malformed
    end
  end

  def of(_), do: :malformed

  @doc "The mode of the configured secret key."
  def current, do: of(Application.get_env(:lowendinsight, :stripe_secret_key))

  @doc """
  Whether this deployment is production.

  Not `MIX_ENV`: a release is always compiled with `MIX_ENV=prod`, so a staging
  deploy and production are indistinguishable by it. `LEI_DEPLOY_ENV` is set in
  `fly.toml`, where it is versioned with the deploy that depends on it.
  """
  def production?(deploy_env \\ Application.get_env(:lowendinsight, :deploy_env)) do
    deploy_env == "production"
  end

  @doc """
  Raises unless the Stripe configuration is safe to boot with.

  Test keys are allowed everywhere, production included: running production on
  a sandbox before go-live is exactly what happens now, and a staging deploy
  must never be pushed towards a live key just to boot.

  Options override application config, for tests: `:key`, `:webhook_secret`,
  `:deploy_env`.
  """
  def validate!(opts \\ []) do
    key = option(opts, :key, :stripe_secret_key)
    webhook_secret = option(opts, :webhook_secret, :stripe_webhook_secret)
    deploy_env = option(opts, :deploy_env, :deploy_env)

    case of(key) do
      :malformed ->
        raise ArgumentError, """
        STRIPE_SECRET_KEY is set but is not a Stripe secret key \
        (begins #{inspect(visible_prefix(key))}).

        Expected sk_test_, sk_live_, rk_test_ or rk_live_. A publishable key \
        (pk_) or a webhook secret (whsec_) in this variable is the usual cause.
        """

      :live ->
        unless production?(deploy_env) do
          raise ArgumentError, """
          A live Stripe key is configured, but LEI_DEPLOY_ENV is \
          #{inspect(deploy_env)}, not "production".

          Live keys charge real money. Use a test key (sk_test_ or rk_test_) \
          here. If this really is production, LEI_DEPLOY_ENV belongs in fly.toml.
          """
        end

      _ ->
        :ok
    end

    if present?(webhook_secret) and not String.starts_with?(webhook_secret, "whsec_") do
      raise ArgumentError, """
      STRIPE_WEBHOOK_SECRET is set but is not a webhook signing secret \
      (begins #{inspect(visible_prefix(webhook_secret))}).

      Expected whsec_. Every delivery would fail verification. An API key in \
      this variable is the usual cause.
      """
    end

    :ok
  end

  defp option(opts, name, config_key) do
    case Keyword.fetch(opts, name) do
      {:ok, value} -> value
      :error -> Application.get_env(:lowendinsight, config_key)
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  # Enough to recognise what was pasted, never enough to use it. Stripe
  # prefixes end at the second underscore; nothing after that is shown.
  defp visible_prefix(value) when is_binary(value) do
    case String.split(value, "_", parts: 3) do
      [a, b, _secret] -> "#{a}_#{b}_"
      [a, _secret] -> "#{a}_"
      _ -> String.slice(value, 0, 3)
    end
  end

  defp visible_prefix(_), do: ""
end
