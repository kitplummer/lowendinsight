# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, :console, format: "lei: $time $metadata[$level] $message\n"

# --- lei_service base config ---

# Lei.Repo first: it owns orgs and api_keys, which LeiService reads.
config :lei_service, ecto_repos: [Lei.Repo, LeiService.Repo]

# Lei.Repo's migrations live apart from LeiService.Repo's (ADR-003). Read
# from config, not from `use Ecto.Repo`: passed there it is ignored, Lei.Repo
# falls back to priv/repo/migrations, and finds none of its own -- reporting
# "already up" on a database that has them and creating nothing on one that
# does not.
config :lei_service, Lei.Repo, priv: "priv/lei_repo"

config :lei_service, LeiService.Endpoint,
  port: String.to_integer(System.get_env("PORT") || "4000")

config :lei_service,
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
  medium_currency_level: String.to_integer(System.get_env("LEI_MEDIUM_CURRENCY_LEVEL") || "26"),
  critical_large_commit_level:
    String.to_float(System.get_env("LEI_CRITICAL_LARGE_COMMIT_LEVEL") || "0.30"),
  high_large_commit_level:
    String.to_float(System.get_env("LEI_HIGH_LARGE_COMMIT_LEVEL") || "0.15"),
  medium_large_commit_level:
    String.to_float(System.get_env("LEI_MEDIUM_LARGE_COMMIT_LEVEL") || "0.05"),
  critical_functional_contributors_level:
    String.to_integer(System.get_env("LEI_CRITICAL_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "2"),
  high_functional_contributors_level:
    String.to_integer(System.get_env("LEI_HIGH_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "3"),
  medium_functional_contributors_level:
    String.to_integer(System.get_env("LEI_MEDIUM_FUNCTIONAL_CONTRIBUTORS_LEVEL") || "5"),
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "1"),
  base_temp_dir: System.get_env("LEI_BASE_TEMP_DIR") || "/tmp",
  critical_agentic_level: String.to_float(System.get_env("LEI_CRITICAL_AGENTIC_LEVEL") || "0.9"),
  high_agentic_level: String.to_float(System.get_env("LEI_HIGH_AGENTIC_LEVEL") || "0.7"),
  medium_agentic_level: String.to_float(System.get_env("LEI_MEDIUM_AGENTIC_LEVEL") || "0.3"),
  session_secret_key_base:
    System.get_env("LEI_SESSION_SECRET") ||
      "lei_dev_session_secret_that_is_at_least_64_bytes_long_for_cookie_store_to_work_properly"

# --- Stripe + ACP ---

config :lowendinsight,
  stripe_secret_key: System.get_env("STRIPE_SECRET_KEY"),
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
  stripe_pro_price_id: System.get_env("STRIPE_PRO_PRICE_ID"),
  stripe_profile_id: System.get_env("STRIPE_PROFILE_ID"),
  lei_base_url: System.get_env("LEI_BASE_URL") || "http://localhost:4000",
  acp_bearer_token: System.get_env("LEI_ACP_BEARER_TOKEN"),
  acp_signing_secret: System.get_env("LEI_ACP_SIGNING_SECRET")

# JsonXema Schema Loader
config :xema, loader: SchemaLoader

# --- Redis ---

config :redix,
  redis_url: System.get_env("REDIS_URL") || "redis://localhost:6379"

# --- Scheduler ---

config :lei_service, LeiService.Scheduler,
  jobs: [
    {"*/5 * * * *", {LeiService.CacheCleaner, :clean, []}},
    {
        # Hourly, never overlapping: each run refreshes only languages not
        # refreshed in the last day, one at a time, so a restart costs one
        # language rather than the night (#158).
        :github_trending,
        [
          schedule: "0 * * * *",
          task: {LeiService.GithubTrending, :refresh_due, []},
          # Re-enabled after #158: disabled 2026-09-14 when its first run
          # OOM-killed production. Bounded since by #162 (analysis memory no
          # longer scales with history) and #163 (rising repositories, 250 MB
          # cap, 90-minute lock).
          overlap: false
        ]
      }
  ]

# Optional dependency health checks surfaced by Lei.Health on /readyz.
# Registered here rather than in the library so :lowendinsight keeps no Redis
# dependency. A failing optional check reports "degraded" (still 200) rather
# than pulling the instance out of rotation.
# Metrics from the web app, collected by Lei.Metrics without the library
# depending on it (#158).
config :lowendinsight,
  metrics_collectors: [{LeiService.GithubTrending, :metrics, []}]

config :lowendinsight,
  optional_health_checks: [
    redis: {LeiService.Health, :check_redis, []},
    # Whether the configured price IDs exist in the Stripe key's mode.
    stripe: {Lei.Stripe.ObjectCheck, :status, []}
  ]

# Rate limit buckets, per minute. free/pro key on the API key; the acp buckets
# key on client IP, because ACP is unauthenticated by design (ADR-001).
# acp_complete is far tighter than acp because completion creates an org and an
# API key, where the other endpoints only write a session row.
config :lowendinsight,
  # payment_settle is much tighter than payment_challenge: asking the price is
  # cheap, but every credential presented can reach Stripe, and that is the
  # half an attacker would use to grind through stolen tokens.
  # The rails the app will accept payment through.
  #
  # Configured rather than discovered, so adding a rail is a deliberate act:
  # Lei.Payments.validate_rails!/0 checks these at boot and refuses a name the
  # ledger cannot record or a cadence a rail cannot perform. An empty list
  # passes that check by having nothing to check, which is the failure this
  # codebase keeps meeting -- so the list is set here rather than left to a
  # default.
  payment_rails: [Lei.Payments.Rails.Mpp, Lei.Payments.Rails.Tempo],
  rate_limits: %{
    free: 60,
    pro: 600,
    acp: 20,
    acp_complete: 5,
    payment_challenge: 30,
    payment_settle: 10,
    # Fresh analyses through the homepage's Try It form, per IP, per hour
    # (window below). Cached reports are not counted (#152).
    try_it: 10
  },
  rate_limit_windows: %{try_it: 3_600_000}

import_config "#{Mix.env()}.exs"
