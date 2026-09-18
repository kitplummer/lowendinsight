# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, level: :debug

# --- lei_service dev overrides ---

config :lei_service,
  check_repo_size?: String.to_atom(System.get_env("LEI_CHECK_REPO_SIZE") || "true"),
  gh_token: System.get_env("LEI_GH_TOKEN") || "",
  num_of_repos: String.to_integer(System.get_env("LEI_NUM_OF_REPOS") || "10"),
  wait_time: String.to_integer(System.get_env("LEI_WAIT_TIME") || "1800000"),
  use_workers: true

config :redix,
  timeout: :infinity

config :lei_service, LeiService.Repo,
  database: "lei_service_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 5

config :lei_service, Oban,
  repo: LeiService.Repo,
  queues: [analysis: 2, trending: 1, maintenance: 1]

# --- lowendinsight (library) dev overrides ---

config :lei_service, Lei.Repo,
  database: "lowendinsight_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 5

config :lowendinsight,
  jobs_per_core_max: String.to_integer(System.get_env("LEI_JOBS_PER_CORE_MAX") || "2")

# --- ACP (local development) ---

# Lei.Acp.Auth refuses a request it cannot authenticate. Neither
# LEI_ACP_BEARER_TOKEN nor LEI_ACP_SIGNING_SECRET is set locally, and an
# absent secret used to mean "authenticated" -- which is exactly how
# /acp/checkout came to be open in production. Development opts in
# explicitly instead, so that production, where this file is not loaded,
# fails closed.
config :lei_service, acp_allow_unauthenticated: true
