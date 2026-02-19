defmodule CounterAgentTest do
  use ExUnit.Case, async: true

  test "new starts agent at 0" do
    {:ok, pid} = CounterAgent.new()
    assert CounterAgent.get(pid) == 0
    Agent.stop(pid)
  end

  test "click increments and returns new value" do
    {:ok, pid} = CounterAgent.new()
    assert CounterAgent.click(pid) == 1
    assert CounterAgent.click(pid) == 2
    assert CounterAgent.click(pid) == 3
    Agent.stop(pid)
  end

  test "set changes the value" do
    {:ok, pid} = CounterAgent.new()
    CounterAgent.set(pid, 42)
    assert CounterAgent.get(pid) == 42
    Agent.stop(pid)
  end

  test "set then click continues from set value" do
    {:ok, pid} = CounterAgent.new()
    CounterAgent.set(pid, 10)
    assert CounterAgent.click(pid) == 11
    Agent.stop(pid)
  end
end
