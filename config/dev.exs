# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, level: :debug

# --- lowendinsight_get dev overrides ---

config :lowendinsight_get,
  check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "true"),
  gh_token: System.get_env("LEI_GH_TOKEN") || "",
  num_of_repos: String.to_integer(System.get_env("LEI_NUM_OF_REPOS") || "10"),
  wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "1800000"),
  use_workers: true

config :redix,
  timeout: :infinity

config :lowendinsight_get, LowendinsightGet.Repo,
  database: "lowendinsight_get_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 5

config :lowendinsight_get, Oban,
  repo: LowendinsightGet.Repo,
  queues: [analysis: 2]

# --- lowendinsight (library) dev overrides ---

config :lowendinsight,
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "2")
