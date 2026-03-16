# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

import Config

config :logger, :console, format: "lei: $time $metadata[$level] $message\n"

# Agentic detection thresholds (runtime env vars, overridable at deploy time):
#   LEI_AGENTIC_MIXED_THRESHOLD  — lower bound for "mixed" classification (default 0.3)
#   LEI_AGENTIC_AGENT_THRESHOLD  — lower bound for "agent" classification (default 0.7)
#
# Deprecated (no longer used, emit a warning if set):
#   LEI_CRITICAL_AGENTIC_LEVEL
#   LEI_HIGH_AGENTIC_LEVEL
#   LEI_MEDIUM_AGENTIC_LEVEL

import_config "#{Mix.env()}.exs"
