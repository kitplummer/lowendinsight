# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Configure ExUnit exclusions based on environment
# In CI, exclude network and long-running tests by default
#
# Test modes:
#   CI (default):     mix test (auto-excludes network and long)
#   Local (default):  mix test (auto-excludes long only)
#   Full suite:       mix test --include long --include network
#   Network only:     mix test --only network --include long
#   Long only:        mix test --only long
#
exclusions =
  if System.get_env("CI") do
    [network: true, long: true]
  else
    # Locally, only exclude long tests by default
    [long: true]
  end

# Use max_cases: 1 in CI to avoid parallel test file loading race conditions
max_cases = if System.get_env("CI"), do: 1, else: System.schedulers_online() * 2
ExUnit.start(exclude: exclusions, max_cases: max_cases)

# Compile support files
Code.require_file("support/fixture_helper.ex", __DIR__)

# Configure Mox for behaviour-based mocking
Mox.defmock(GitModule.Mock, for: GitModule.Behaviour)

# Set up application config to use mock in tests when needed
# Tests can use: Application.put_env(:lowendinsight, :git_module, GitModule.Mock)
# And then revert: Application.put_env(:lowendinsight, :git_module, GitModule)
