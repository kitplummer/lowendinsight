# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

# Runtime configuration — evaluated at boot time (not compile time).
# All env-var-dependent config belongs here.

# Where this is deployed, as distinct from how it was compiled: a release is
# always MIX_ENV=prod, so only this tells production from staging. Set in
# fly.toml. Lei.Stripe.Mode refuses a live Stripe key unless it is "production".
config :lei_service, deploy_env: System.get_env("LEI_DEPLOY_ENV")

if config_env() == :prod do
  config :lei_service, LeiService.Endpoint,
    port: String.to_integer(System.get_env("PORT") || "4444"),
    ip: {0, 0, 0, 0}

  jwt_secret =
    System.get_env("LEI_JWT_SECRET") ||
      raise "LEI_JWT_SECRET env var is required in production"

  # Read here, at boot, not in config.exs. config.exs is evaluated when the
  # release is *built*, where no Fly secret exists, so production silently ran
  # with the development defaults for both of these -- the session secret
  # committed to this repository and a known JWT secret for Lei.Auth -- whatever
  # was set in Fly (security, 2026-09-14). A missing or placeholder session
  # secret now stops the release instead of signing cookies anyone can forge.
  session_secret =
    System.get_env("LEI_SESSION_SECRET") ||
      raise "LEI_SESSION_SECRET env var is required in production"

  if byte_size(session_secret) < 64 do
    raise "LEI_SESSION_SECRET must be at least 64 bytes"
  end

  if String.starts_with?(session_secret, "lei_dev_session_secret") do
    raise "LEI_SESSION_SECRET is the development default; generate a real one"
  end

  config :lei_service,
    # Lei.Auth verifies JWTs on Lei.Web.Router's own listener (start_http) with
    # this. It must be the same secret the endpoint's LeiService.Auth uses.
    jwt_secret: jwt_secret,
    session_secret_key_base: session_secret

  config :lei_service,
    jwt_secret: jwt_secret,
    cache_ttl: String.to_integer(System.get_env("LEI_CACHE_TTL") || "30"),
    cache_clean_enable: String.to_atom(System.get_env("LEI_CACHE_CLEAN_ENABLE") || "true"),
    check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "true"),
    wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "7200000"),
    num_of_repos: String.to_integer(System.get_env("LEI_NUM_OF_REPOS") || "10"),
    gh_token: System.get_env("LEI_GH_TOKEN") || "",
    languages: [
      "elixir",
      "python",
      "go",
      "rust",
      "java",
      "javascript",
      "ruby",
      "c++",
      "c#",
      "haskell",
      "scala",
      "swift",
      "kotlin",
      "dart"
    ]

  config :lei_service,
    # Two HTTP listeners run in production, deliberately:
    #
    #   8080  LeiService.Endpoint -- the Fly entry point (fly.toml
    #         internal_port). Lei.Web.Router is mounted inside it for the paths
    #         listed in @auth_paths.
    #   4000  Lei.Web.Router standalone, started by start_http below. This is
    #         the Kubernetes and Zarf entry point: apps/lowendinsight/manifests/
    #         service.yaml targets port 4000.
    #
    # On Fly the 4000 listener receives no traffic, since only 8080 is routed.
    # It is NOT dead code -- removing it as Fly cleanup would break the UDS
    # deployment path (#19). Set LEI_START_HTTP=false to disable it where only
    # the Fly entry point is needed.
    start_http: System.get_env("LEI_START_HTTP", "true") == "true",
    http_port: String.to_integer(System.get_env("LEI_HTTP_PORT") || "4000")

  config :lowendinsight,
    critical_contributor_level:
      String.to_integer(System.get_env("LEI_CRITICAL_CONTRIBUTOR_LEVEL") || "2"),
    high_contributor_level: System.get_env("LEI_HIGH_CONTRIBUTOR_LEVEL") || 3,
    medium_contributor_level: System.get_env("LEI_CRITICAL_CONTRIBUTOR_LEVEL") || 5,
    critical_currency_level:
      String.to_integer(System.get_env("LEI_CRITICAL_CURRENCY_LEVEL") || "104"),
    high_currency_level:
      String.to_integer(System.get_env("LEI_HIGH_CURRENCY_LEVEL") || "52"),
    medium_currency_level:
      String.to_integer(System.get_env("LEI_MEDIUM_CURRENCY_LEVEL") || "26"),
    ## Functional commit currency (#244): time since the last commit that carried
    ## information -- not a bot bump, not a README fix. Configured apart from the
    ## plain currency levels above because the substantive date is always at or
    ## before the plain one, so shared thresholds would let this metric shadow it
    ## entirely and make tuning either one move both.
    critical_functional_currency_level:
      String.to_integer(System.get_env("LEI_CRITICAL_FUNCTIONAL_CURRENCY_LEVEL") || "104"),
    high_functional_currency_level:
      String.to_integer(System.get_env("LEI_HIGH_FUNCTIONAL_CURRENCY_LEVEL") || "52"),
    medium_functional_currency_level:
      String.to_integer(System.get_env("LEI_MEDIUM_FUNCTIONAL_CURRENCY_LEVEL") || "26"),
    critical_large_commit_level:
      String.to_float(System.get_env("LEI_CRITICAL_LARGE_COMMIT_LEVEL") || "0.30"),
    high_large_commit_level:
      String.to_float(System.get_env("LEI_HIGH_LARGE_COMMIT_LEVEL") || "0.15"),
    medium_large_commit_level:
      String.to_float(System.get_env("LEI_MEDIUM_LARGE_COMMIT_LEVEL") || "0.05"),
    critical_functional_contributors_level:
      String.to_integer(
        System.get_env("LEI_CRITICAL_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "2"
      ),
    high_functional_contributors_level:
      String.to_integer(
        System.get_env("LEI_HIGH_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "3"
      ),
    medium_functional_contributors_level:
      String.to_integer(
        System.get_env("LEI_MEDIUM_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "5"
      ),
    jobs_per_core_max:
      String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "2"),
    base_temp_dir: System.get_env("LEI_BASE_TEMP_DIR") || "/tmp"

  # Database
  # Fail fast rather than falling back to localhost. A production boot that
  # silently points at a database that is not there produces confusing
  # downstream errors -- connection refused from Ecto, /readyz reporting the
  # database check as failing -- none of which name the actual cause. Matches
  # how LEI_JWT_SECRET is handled above.
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL env var is required in production"

  config :lei_service, LeiService.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    socket_options: [:inet6]

  config :lei_service, Lei.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    socket_options: [:inet6]

  config :lei_service, Oban,
    repo: LeiService.Repo,
    queues: [
      analysis: String.to_integer(System.get_env("OBAN_ANALYSIS_CONCURRENCY") || "5"),
      trending: 1,
      maintenance: 1
    ]

  # Redis
  config :redix,
    redis_url: System.get_env("REDIS_URL")

  # Fly's private network (6PN) is IPv6-only, and Redix defaults to IPv4.
  # Override with LEI_REDIS_IPV6=false when running against an IPv4 Redis.
  config :lei_service,
    redis_socket_opts:
      if(System.get_env("LEI_REDIS_IPV6", "true") == "true", do: [:inet6], else: [])

  # Stripe + ACP
  config :lei_service,
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY"),
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
    stripe_pro_price_id: System.get_env("STRIPE_PRO_PRICE_ID"),
    stripe_metered_price_id: System.get_env("STRIPE_METERED_PRICE_ID"),
    # The Stripe profile agents' Shared Payment Tokens are scoped to. Without
    # it the MPP rail issues no challenge (#143).
    stripe_profile_id: System.get_env("STRIPE_PROFILE_ID"),
    # A Stripe crypto deposit address on Tempo, created with the same key. The
    # tempo rail names it in challenges only once Stripe confirms it (#144).
    tempo_deposit_address: System.get_env("TEMPO_DEPOSIT_ADDRESS"),
    # Customer-facing: Stripe Checkout success/cancel redirects and the
    # payment-intent return_url. Must be the canonical domain, not the
    # fly.dev hostname, or paying customers land on the wrong brand.
    lei_base_url: System.get_env("LEI_BASE_URL") || "https://lowendinsight.dev",
    acp_bearer_token: System.get_env("LEI_ACP_BEARER_TOKEN"),
    acp_signing_secret: System.get_env("LEI_ACP_SIGNING_SECRET")

  # Usage billing rates (ADR-001)
  config :lei_service,
    cache_hit_cost_cents:
      String.to_float(System.get_env("LEI_CACHE_HIT_COST_CENTS") || "0.5"),
    cache_miss_cost_cents:
      String.to_float(System.get_env("LEI_CACHE_MISS_COST_CENTS") || "5.0"),
    free_tier_monthly_limit:
      String.to_integer(System.get_env("LEI_FREE_TIER_MONTHLY_LIMIT") || "200"),
    pro_tier_credit_cents:
      String.to_float(System.get_env("LEI_PRO_TIER_CREDIT_CENTS") || "1500.0")
end
