# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

# Runtime configuration — evaluated at boot time (not compile time).
# All env-var-dependent config belongs here.

if config_env() == :prod do
  config :lowendinsight_get, LowendinsightGet.Endpoint,
    port: String.to_integer(System.get_env("PORT") || "4444"),
    ip: {0, 0, 0, 0}

  jwt_secret =
    System.get_env("LEI_JWT_SECRET") ||
      raise "LEI_JWT_SECRET env var is required in production"

  config :lowendinsight_get,
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

  config :lowendinsight,
    start_http: true,
    http_port: String.to_integer(System.get_env("LEI_HTTP_PORT") || "4000"),
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
  database_url =
    System.get_env("DATABASE_URL") ||
      "ecto://postgres:postgres@localhost/lowendinsight_get_prod"

  config :lowendinsight_get, LowendinsightGet.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    socket_options: [:inet6]

  config :lowendinsight, Lei.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    socket_options: [:inet6]

  config :lowendinsight_get, Oban,
    repo: LowendinsightGet.Repo,
    queues: [
      analysis:
        String.to_integer(System.get_env("OBAN_ANALYSIS_CONCURRENCY") || "5")
    ]

  # Redis
  config :redix,
    redis_url: System.get_env("REDIS_URL")

  # Scheduler
  config :lowendinsight_get, LowendinsightGet.Scheduler,
    jobs: [
      {"*/5 * * * *", {LowendinsightGet.CacheCleaner, :clean, []}},
      {"0 0 * * *", {LowendinsightGet.GithubTrending, :process_languages, []}}
    ]

  # Stripe + ACP
  config :lowendinsight,
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY"),
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
    stripe_pro_price_id: System.get_env("STRIPE_PRO_PRICE_ID"),
    stripe_metered_price_id: System.get_env("STRIPE_METERED_PRICE_ID"),
    lei_base_url: System.get_env("LEI_BASE_URL") || "https://lowendinsight.fly.dev",
    acp_bearer_token: System.get_env("LEI_ACP_BEARER_TOKEN"),
    acp_signing_secret: System.get_env("LEI_ACP_SIGNING_SECRET")

  # Usage billing rates (ADR-001)
  config :lowendinsight,
    cache_hit_cost_cents:
      String.to_float(System.get_env("LEI_CACHE_HIT_COST_CENTS") || "0.5"),
    cache_miss_cost_cents:
      String.to_float(System.get_env("LEI_CACHE_MISS_COST_CENTS") || "5.0"),
    free_tier_monthly_limit:
      String.to_integer(System.get_env("LEI_FREE_TIER_MONTHLY_LIMIT") || "200"),
    pro_tier_credit_cents:
      String.to_float(System.get_env("LEI_PRO_TIER_CREDIT_CENTS") || "1500.0")
end
