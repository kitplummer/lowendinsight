defmodule LowendinsightGet.CounterAgentTest do
  # Not async. :counter is a single named agent for the whole node, and
  # Analysis.analyze/3 adds the calling process to it whenever it exists --
  # so an async endpoint test analysing a URL while this one ran put its pid
  # into the counter this test had just created, and `map_size(proc) == 0`
  # failed (left: 1). Seen on main at e57f68b and on #175, passing and failing
  # on the same commit.
  use ExUnit.Case, async: false

  test "counter agent adds pid and url, increments, and stops" do
    # A counter left running by an earlier test would carry its processes.
    if Process.whereis(:counter), do: Agent.stop(:counter)

    number_of_urls = 1
    LowendinsightGet.CounterAgent.new_counter(number_of_urls)

    assert Process.whereis(:counter) != nil

    {proc, _log} = LowendinsightGet.CounterAgent.get()
    assert map_size(proc) == 0

    LowendinsightGet.CounterAgent.add(self(), "url")
    {proc, log} = LowendinsightGet.CounterAgent.get()

    assert Map.fetch(proc, self()) == {:ok, :running}
    assert map_size(proc) == 1
    assert log.completed == 0
    assert log.total == number_of_urls
    assert LowendinsightGet.CounterAgent.log_status({proc, log}) == :logged

    LowendinsightGet.CounterAgent.increment(self())
    {proc, log} = LowendinsightGet.CounterAgent.get()
    assert log.completed == 1
    assert LowendinsightGet.CounterAgent.log_status({proc, log}) == :no_log

    LowendinsightGet.CounterAgent.new_counter(6)
    {_proc, log} = LowendinsightGet.CounterAgent.get()
    assert log.total == number_of_urls + 6

    LowendinsightGet.CounterAgent.update_and_stop()
    assert Process.whereis(:counter) == nil
  end
end
