defmodule LeiService.JobTimeoutTest do
  @moduledoc """
  An analysis job is bounded, and a deploy drains rather than kills.

  Without a timeout a job can run forever, which is indistinguishable from
  stuck: Lifeline rescues it after an hour and the next attempt hangs the
  same way. Without a shutdown grace period longer than Fly's kill timeout
  (5 seconds), every deploy killed whatever was running -- which is how 79
  jobs were left executing (ADR-004).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../", __DIR__)

  defp job(urls) do
    %Oban.Job{args: %{"uuid" => "u", "urls" => urls, "start_time" => "2026-09-16T00:00:00Z"}}
  end

  defp minutes(ms), do: div(ms, 60_000)

  test "the timeout grows with the number of repositories" do
    one = LeiService.AnalysisWorker.timeout(job(["https://github.com/o/r"]))
    ten = LeiService.AnalysisWorker.timeout(job(for i <- 1..10, do: "https://github.com/o/r#{i}"))

    assert minutes(one) >= 2, "a single repository needs time to clone and score"
    assert ten > one
    assert minutes(ten) <= 45
  end

  test "the timeout is capped below Lifeline's rescue window" do
    huge =
      LeiService.AnalysisWorker.timeout(job(for i <- 1..10_000, do: "https://github.com/o/r#{i}"))

    rescue_after =
      :lei_service
      |> Application.get_env(Oban, [])
      |> get_in([:lifeline, :rescue_after])
      |> case do
        {n, :minutes} -> n
        nil -> 60
      end

    assert minutes(huge) < rescue_after,
           "a job may not outlive the rescue window, or Lifeline re-runs work that is still running"
  end

  test "a job with no urls still has a timeout" do
    assert LeiService.AnalysisWorker.timeout(job([])) > 0
  end

  test "Oban waits for running jobs before shutting down" do
    grace = Application.get_env(:lei_service, Oban)[:shutdown_grace_period]

    assert is_integer(grace) and grace >= 30_000,
           "a deploy must give a running analysis time to finish"
  end

  test "Fly's kill timeout is longer than Oban's shutdown grace period" do
    fly = File.read!(Path.join(@root, "fly.toml"))
    [_, kill_timeout] = Regex.run(~r/^kill_timeout\s*=\s*"?(\d+)"?/m, fly)
    grace = Application.get_env(:lei_service, Oban)[:shutdown_grace_period]

    assert String.to_integer(kill_timeout) * 1000 > grace,
           "fly kills the machine after #{kill_timeout}s, before Oban's #{div(grace, 1000)}s grace period ends"
  end
end
