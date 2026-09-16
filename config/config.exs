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
  medium_agentic_level: String.to_float(System.get_env("LEI_MEDIUM_AGENTIC_LEVEL") || "0.3")

# The service's settings live under :lei_service, never :lowendinsight: the
# library's environment holds only analyzer settings (ADR-003), so nothing an
# application configures for the service can reach a library report.
config :lei_service,
  session_secret_key_base:
    System.get_env("LEI_SESSION_SECRET") ||
      "lei_dev_session_secret_that_is_at_least_64_bytes_long_for_cookie_store_to_work_properly"

# --- Stripe + ACP ---

config :lei_service,
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

# Scheduled work runs as Oban jobs (ADR-004): a run that does not happen is
# visible in oban_jobs, and survives the restart that lost a Quantum tick.

# Optional dependency health checks surfaced by Lei.Health on /readyz.
# Registered here rather than in the library so :lowendinsight keeps no Redis
# dependency. A failing optional check reports "degraded" (still 200) rather
# than pulling the instance out of rotation.
# Metrics from the web app, collected by Lei.Metrics without the library
# depending on it (#158).
config :lei_service,
  metrics_collectors: [
    {LeiService.GithubTrending, :metrics, []},
    {LeiService.QueueHealth, :metrics, []}
  ]

config :lei_service,
  optional_health_checks: [
    redis: {LeiService.Health, :check_redis, []},
    # Whether the configured price IDs exist in the Stripe key's mode.
    stripe: {Lei.Stripe.ObjectCheck, :status, []},
    # Whether background work is moving: nothing stuck executing, nothing
    # waiting too long to start (ADR-004).
    queue: {LeiService.QueueHealth, :status, []}
  ]

# Rate limit buckets, per minute. free/pro key on the API key; the acp buckets
# key on client IP, because ACP is unauthenticated by design (ADR-001).
# acp_complete is far tighter than acp because completion creates an org and an
# API key, where the other endpoints only write a session row.
config :lei_service,
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
    # The unauthenticated account routes, per IP, per hour (windows below).
    # recover is tightest: it answers with a new admin API key, so guesses at
    # a recovery code are an organisation takeover attempt.
    signup: 5,
    login: 10,
    recover: 5,
    # Fresh analyses through the homepage's Try It form, per IP, per hour
    # (window below). Cached reports are not counted (#152).
    try_it: 10
  },
  rate_limit_windows: %{
    try_it: 3_600_000,
    signup: 3_600_000,
    login: 3_600_000,
    recover: 3_600_000
  }

# An operator token may be valid for at most this long. Without a ceiling a
# token minted with a distant exp is the forever-credential that missing
# expiry checks allowed (security review, 2026-09-14).
config :lei_service, operator_token_max_lifetime_seconds: 86_400

# Oban runs no plugins unless configured. Without Lifeline a job that was
# executing when the node stopped (a deploy) stays `executing` forever and its
# analysis never finishes; without Pruner finished jobs accumulate. Lifeline
# rescues by time alone, so rescue_after must exceed the longest real analysis.
# Environment files add repo and queues; test.exs sets plugins: false.
# stuck_after_minutes must exceed Lifeline's rescue_after below: a job Lifeline
# would still rescue is slow, not stuck.
config :lei_service, :queue_health, stuck_after_minutes: 90, backlog_after_minutes: 15

config :lei_service, Oban,
  cron: [
    crontab: [
      # Trending is parked (#206): the code and its routes remain, nothing
      # schedules it. Its source -- OSS Insight's event-derived ranking -- has
      # been unavailable since 2026-03-01, what remained was a GitHub Search
      # proxy, and it was the most expensive thing we ran. Re-add this entry
      # to turn it back on.
      {"*/5 * * * *", LeiService.CacheCleanerWorker}
    ]
  ],
  # A deploy stops the node: wait for a running analysis instead of killing
  # it. fly.toml's kill_timeout must stay above this, or Fly kills the
  # machine mid-wait (ADR-004).
  shutdown_grace_period: 60_000,
  lifeline: [rescue_after: {60, :minutes}],
  pruner: [max_age: {7, :days}]

import_config "#{config_env()}.exs"
