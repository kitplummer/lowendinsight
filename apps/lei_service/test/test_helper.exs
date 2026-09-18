# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Exclude network tests by default — they are non-deterministic (DNS, timeouts,
# rate limits) and should never block commits or CI runs.
# Run with: mix test --include network
ExUnit.start(exclude: [network: true])

# Lei.Repo belongs to this app since ADR-003; its tests check out connections
# explicitly.
Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, :manual)

# LeiService.Repo, which Oban writes through, is sandboxed the same way. Until
# it was, a test that enqueued a job committed it, and those jobs made the next
# run's readiness report the queue backed up once they were older than
# backlog_after_minutes (15) -- failing OpsRoutingTest, HealthEndpointsTest and
# HealthTest in whichever run came more than 15 minutes after the last, which
# is why no seed ever reproduced it (2026-09-17, #217).
#
# The clearing that stood in for this is gone with it: a suite that has to
# tidy up after itself before it starts is describing a leak, not preventing
# one.
Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, :manual)

# Stripe and the Tempo RPC are reached through these behaviours in tests.
for {mock, behaviour} <- [
      {Lei.StripeMock, Lei.StripeBehaviour},
      {Lei.TempoRpcMock, Lei.Tempo.RpcBehaviour}
    ],
    not Code.ensure_loaded?(mock) do
  Mox.defmock(mock, for: behaviour)
end

defmodule Getter do
  def there_yet?(test, key) do
    case test do
      true ->
        :ok

      false ->
        :timer.sleep(100)

        case Redix.command(:redix, ["GET", key]) do
          {:ok, _} -> there_yet?(true, key)
          {:error, _} -> there_yet?(false, key)
        end
    end
  end
end
