# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, :console, format: "lei: $time $metadata[$level] $message\n"

# --- lowendinsight_get base config ---

config :lowendinsight_get, ecto_repos: [LowendinsightGet.Repo]

config :lowendinsight_get, LowendinsightGet.Endpoint,
  port: String.to_integer(System.get_env("PORT") || "4000")

config :lowendinsight_get,
  jwt_secret: System.get_env("LEI_JWT_SECRET") || "my super secret",
  cache_ttl: String.to_integer(System.get_env("LEI_CACHE_TTL") || "30"),
  cache_ttl_seconds:
    String.to_integer(
      System.get_env("LEI_CACHE_TTL_SECONDS") ||
        Integer.to_string(String.to_integer(System.get_env("LEI_CACHE_TTL") || "30") * 86400)
    ),
  cache_clean_enable: String.to_atom(System.get_env("LEI_CACHE_CLEAN_ENABLE") || "true"),
  check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "true"),
  default_cache_timeout:
    String.to_integer(System.get_env("LEI_DEFAULT_CACHE_TIMEOUT") || "30000"),
  wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "7200000"),
  gh_token: System.get_env("LEI_GH_TOKEN") || "",
  num_of_repos: System.get_env("LEI_NUM_OF_REPOS") || "10",
  languages: [
    "elixir",
    "python",
    "go",
    "dart",
    "rust",
    "java",
    "javascript",
    "ruby",
    "c",
    "c++",
    "c#",
    "haskell",
    "php",
    "scala",
    "swift",
    "objective-c",
    "kotlin",
    "shell",
    "typescript"
  ]

# --- lowendinsight (library) Ecto repo ---

config :lowendinsight, ecto_repos: [Lei.Repo]

config :lowendinsight,
  jwt_secret: System.get_env("LEI_JWT_SECRET") || "lei_dev_secret"

# --- lowendinsight (library) risk thresholds ---

config :lowendinsight,
  sbom_risk_level: System.get_env("LEI_SBOM_RISK_LEVEL") || "medium",
  critical_contributor_level:
    String.to_integer(System.get_env("LEI_CRITICAL_CONTRIBUTOR_LEVEL") || "2"),
  high_contributor_level: System.get_env("LEI_HIGH_CONTRIBUTOR_LEVEL") || 3,
  medium_contributor_level: System.get_env("LEI_CRITICAL_CONTRIBUTOR_LEVEL") || 5,
  critical_currency_level:
    String.to_integer(System.get_env("LEI_CRITICAL_CURRENCY_LEVEL") || "104"),
  high_currency_level: String.to_integer(System.get_env("LEI_HIGH_CURRENCY_LEVEL") || "52"),
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
    String.to_integer(System.get_env("LEI_HIGH_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "3"),
  medium_functional_contributors_level:
    String.to_integer(
      System.get_env("LEI_MEDIUM_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "5"
    ),
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "1"),
  base_temp_dir: System.get_env("LEI_BASE_TEMP_DIR") || "/tmp",
  critical_agentic_level:
    String.to_float(System.get_env("LEI_CRITICAL_AGENTIC_LEVEL") || "0.9"),
  high_agentic_level:
    String.to_float(System.get_env("LEI_HIGH_AGENTIC_LEVEL") || "0.7"),
  medium_agentic_level:
    String.to_float(System.get_env("LEI_MEDIUM_AGENTIC_LEVEL") || "0.3"),
  session_secret_key_base:
    System.get_env("LEI_SESSION_SECRET") ||
      "lei_dev_session_secret_that_is_at_least_64_bytes_long_for_cookie_store_to_work_properly"

# --- Stripe + ACP ---

config :lowendinsight,
  stripe_secret_key: System.get_env("STRIPE_SECRET_KEY"),
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
  stripe_pro_price_id: System.get_env("STRIPE_PRO_PRICE_ID"),
  lei_base_url: System.get_env("LEI_BASE_URL") || "http://localhost:4000",
  acp_bearer_token: System.get_env("LEI_ACP_BEARER_TOKEN"),
  acp_signing_secret: System.get_env("LEI_ACP_SIGNING_SECRET")

# JsonXema Schema Loader
config :xema, loader: SchemaLoader

# --- Redis ---

config :redix,
  redis_url: System.get_env("REDIS_URL") || "redis://localhost:6379"

# --- Scheduler ---

config :lowendinsight_get, LowendinsightGet.Scheduler,
  jobs: [
    {"*/5 * * * *", {LowendinsightGet.CacheCleaner, :clean, []}},
    {"0 0 * * *", {LowendinsightGet.GithubTrending, :analyze, []}}
  ]

import_config "#{Mix.env()}.exs"
