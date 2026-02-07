# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, :console, format: "lei: $time $metadata[$level] $message\n"

config :lowendinsight, Lei.Repo,
  database: "lei_#{Mix.env()}.db"

config :lowendinsight, ecto_repos: [Lei.Repo]

import_config "#{Mix.env()}.exs"
