defmodule Lei.HTTP.RetryTest do
  use ExUnit.Case, async: true

  alias Lei.HTTP.Retry

  # A request that returns each result in turn and records how many calls were
  # made and how long it was told to sleep between them.
  defp scripted(results) do
    {:ok, agent} = Agent.start_link(fn -> %{results: results, calls: 0, slept: []} end)

    request = fn ->
      Agent.get_and_update(agent, fn %{results: [r | rest]} = s ->
        {r, %{s | results: if(rest == [], do: [r], else: rest), calls: s.calls + 1}}
      end)
    end

    sleep = fn ms -> Agent.update(agent, &%{&1 | slept: [ms | &1.slept]}) end
    stats = fn -> Agent.get(agent, &%{calls: &1.calls, slept: Enum.reverse(&1.slept)}) end
    {request, sleep, stats}
  end

  defp ok(status), do: {:ok, %HTTPoison.Response{status_code: status, body: "#{status}"}}
  defp err(reason), do: {:error, %HTTPoison.Error{reason: reason}}

  test "a success is returned on the first call, with no sleep" do
    {request, sleep, stats} = scripted([ok(200)])
    assert Retry.request(request, sleep: sleep, wait: 10) == ok(200)
    assert stats.() == %{calls: 1, slept: []}
  end

  for reason <- [:timeout, :connect_timeout, :closed, :nxdomain] do
    test "a #{reason} error is retried until the request succeeds" do
      {request, sleep, stats} = scripted([err(unquote(reason)), err(unquote(reason)), ok(200)])
      assert Retry.request(request, sleep: sleep, wait: 7) == ok(200)
      assert stats.() == %{calls: 3, slept: [7, 7]}
    end
  end

  test "a 500 is retried until the request succeeds" do
    {request, sleep, stats} = scripted([ok(500), ok(200)])
    assert Retry.request(request, sleep: sleep, wait: 1) == ok(200)
    assert stats.().calls == 2
  end

  test "after max_attempts calls the last result is returned, not raised" do
    {request, sleep, stats} = scripted([err(:timeout)])
    assert Retry.request(request, sleep: sleep, max_attempts: 3, wait: 1) == err(:timeout)
    assert stats.() == %{calls: 3, slept: [1, 1]}
  end

  test "max_attempts: 1 makes one call and never sleeps" do
    {request, sleep, stats} = scripted([ok(500)])
    assert Retry.request(request, sleep: sleep, max_attempts: 1) == ok(500)
    assert stats.() == %{calls: 1, slept: []}
  end

  for status <- [404, 403, 429, 503, 302] do
    test "a #{status} is returned without retrying" do
      {request, sleep, stats} = scripted([ok(unquote(status)), ok(200)])
      assert Retry.request(request, sleep: sleep) == ok(unquote(status))
      assert stats.().calls == 1
    end
  end

  test "an unrecognised transport error is returned without retrying" do
    {request, sleep, stats} = scripted([err(:econnrefused), ok(200)])
    assert Retry.request(request, sleep: sleep) == err(:econnrefused)
    assert stats.().calls == 1
  end

  test "a non-positive max_attempts is rejected rather than making no call" do
    assert_raise ArgumentError, fn -> Retry.request(fn -> ok(200) end, max_attempts: 0) end
  end

  test "defaults match the retry policy the scanners used: 5 attempts, 15s apart" do
    {request, sleep, stats} = scripted([err(:closed)])
    Retry.request(request, sleep: sleep)
    assert stats.() == %{calls: 5, slept: List.duplicate(15_000, 4)}
  end
end
