# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, level: :error

# --- lowendinsight_get test overrides ---

config :lowendinsight_get, LowendinsightGet.Endpoint, port: 4444

config :lowendinsight_get,
  cache_ttl: String.to_integer(System.get_env("LEI_CACHE_TTL") || "30"),
  cache_clean_enable: String.to_atom(System.get_env("LEI_CACHE_CLEAN_ENABLE") || "true"),
  check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "true"),
  wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "1800000"),
  num_of_repos: String.to_integer(System.get_env("LEI_NUM_OF_REPOS") || "10"),
  gh_token: System.get_env("LEI_GH_TOKEN") || "",
  use_workers: false

config :lowendinsight_get, LowendinsightGet.Repo,
  database: "lowendinsight_get_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :lowendinsight_get, Oban,
  repo: LowendinsightGet.Repo,
  testing: :manual,
  queues: false,
  plugins: false

config :redix,
  redis_url: System.get_env("REDIS_URL") || "redis://localhost:6379/2"

# --- lowendinsight (library) test overrides ---

config :lowendinsight, Lei.Repo,
  database: "lowendinsight_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

# Use LEI library's original thresholds so library unit tests pass

config :lowendinsight,
  critical_large_commit_level:
    String.to_float(System.get_env("LEI_CRITICAL_LARGE_COMMIT_LEVEL") || "0.40"),
  high_large_commit_level:
    String.to_float(System.get_env("LEI_HIGH_LARGE_COMMIT_LEVEL") || "0.30"),
  medium_large_commit_level:
    String.to_float(System.get_env("LEI_MEDIUM_LARGE_COMMIT_LEVEL") || "0.20"),
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "1")
