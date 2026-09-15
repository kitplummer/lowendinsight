defmodule LeiService.CounterAgentTest do
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
    LeiService.CounterAgent.new_counter(number_of_urls)

    assert Process.whereis(:counter) != nil

    {proc, _log} = LeiService.CounterAgent.get()
    assert map_size(proc) == 0

    LeiService.CounterAgent.add(self(), "url")
    {proc, log} = LeiService.CounterAgent.get()

    assert Map.fetch(proc, self()) == {:ok, :running}
    assert map_size(proc) == 1
    assert log.completed == 0
    assert log.total == number_of_urls
    assert LeiService.CounterAgent.log_status({proc, log}) == :logged

    LeiService.CounterAgent.increment(self())
    {proc, log} = LeiService.CounterAgent.get()
    assert log.completed == 1
    assert LeiService.CounterAgent.log_status({proc, log}) == :no_log

    LeiService.CounterAgent.new_counter(6)
    {_proc, log} = LeiService.CounterAgent.get()
    assert log.total == number_of_urls + 6

    LeiService.CounterAgent.update_and_stop()
    assert Process.whereis(:counter) == nil
  end
end
