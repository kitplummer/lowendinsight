# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, level: :info

# --- lowendinsight_get prod overrides ---

config :lowendinsight_get, LowendinsightGet.Endpoint,
  port: String.to_integer(System.get_env("PORT") || "4444")

config :lowendinsight_get,
  check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "false"),
  wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "7200000"),
  num_of_repos: String.to_integer(System.get_env("LEI_NUM_OF_REPOS") || "10"),
  gh_token: System.get_env("LEI_GH_TOKEN") || "",
  use_workers: true,
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

config :redix,
  redis_url: System.get_env("REDIS_URL")

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://postgres:postgres@localhost/lowendinsight_get_prod"

config :lowendinsight_get, LowendinsightGet.Repo,
  url: database_url,
  pool_size: 5

config :lowendinsight, Lei.Repo,
  url: database_url,
  pool_size: 5

config :lowendinsight_get, Oban,
  repo: LowendinsightGet.Repo,
  queues: [
    analysis: String.to_integer(System.get_env("OBAN_ANALYSIS_CONCURRENCY") || "5")
  ]

# --- lowendinsight (library) prod overrides ---

config :lowendinsight,
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "2"),
  airgapped_mode: System.get_env("LEI_AIRGAPPED_MODE") == "true"
