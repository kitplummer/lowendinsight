defmodule Lei.StatsTableOwnerTest do
  @moduledoc """
  A count recorded while serving a request is still there after the request.

  ETS tables belong to the process that creates them and are deleted when it
  exits. `Lei.WebhookStats` created its table lazily, in whichever process
  counted first -- a request process, which ends with the request. Every
  outcome it recorded was deleted with it, so on production
  `lei_stripe_webhook_total` read 0 for every result, including `invalid`, the
  signal #111 exists to raise. Confirmed 2026-09-16: an unsigned POST to
  /webhooks/stripe answered 400 and the next /metrics still showed
  `result="unsigned"} 0`.

  The tables are now created when the application starts, by a process that
  lives as long as it does.
  """
  use ExUnit.Case, async: false

  # Everything happens in processes that exit, as it does when serving
  # requests. Reading the count from the test process would create the table
  # there, where it outlives the test, and the test would pass on the bug.
  defp in_passing(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:result, fun.()}) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_received {:result, result}
    result
  end

  for {module, outcome} <- [{Lei.WebhookStats, :invalid}, {Lei.ReversalStats, :unmatched}] do
    test "#{inspect(module)} keeps a count recorded by a process that has exited" do
      module = unquote(module)
      outcome = unquote(outcome)

      before = in_passing(fn -> module.count(outcome) end)
      in_passing(fn -> module.record(outcome) end)

      assert in_passing(fn -> module.count(outcome) end) == before + 1
    end
  end
end
