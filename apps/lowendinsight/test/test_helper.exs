# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Configure ExUnit exclusions based on environment
# Network and long-running tests are excluded by default everywhere.
# Network tests are inherently non-deterministic (DNS, timeouts, rate limits)
# and should never block local commits or CI.
#
# Test modes:
#   Default:          mix test (excludes network and long)
#   Full suite:       mix test --include long --include network
#   Network only:     mix test --only network
#   Long only:        mix test --only long
#
exclusions = [network: true, long: true]

ExUnit.start(exclude: exclusions)

Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, :manual)

# Compile support files
Code.require_file("support/fixture_helper.ex", __DIR__)

# Configure Mox for behaviour-based mocking
Mox.defmock(GitModule.Mock, for: GitModule.Behaviour)
Mox.defmock(Lei.StripeMock, for: Lei.StripeBehaviour)

# Set up application config to use mock in tests when needed
# Tests can use: Application.put_env(:lowendinsight, :git_module, GitModule.Mock)
# And then revert: Application.put_env(:lowendinsight, :git_module, GitModule)
