# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, :console, format: "lei: $time $metadata[$level] $message\n"

config :lowendinsight, ecto_repos: [Lei.Repo]

config :lowendinsight,
  jwt_secret: System.get_env("LEI_JWT_SECRET") || "lei_dev_secret"

import_config "#{Mix.env()}.exs"
