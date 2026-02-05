# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Configure ExUnit exclusions based on environment
# In CI, exclude network and long-running tests by default
exclusions =
  if System.get_env("CI") do
    [network: true, long: true]
  else
    # Locally, only exclude long tests by default
    # Run `mix test --include long` for full suite
    # Run `mix test --include network` for network tests
    [long: true]
  end

ExUnit.start(exclude: exclusions)

# Compile support files
Code.require_file("support/fixture_helper.ex", __DIR__)

# Configure Mox for behaviour-based mocking
Mox.defmock(GitModule.Mock, for: GitModule.Behaviour)

# Set up application config to use mock in tests when needed
# Tests can use: Application.put_env(:lowendinsight, :git_module, GitModule.Mock)
# And then revert: Application.put_env(:lowendinsight, :git_module, GitModule)
