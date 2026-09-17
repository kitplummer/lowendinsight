defmodule LeiService.QuantumRemovedTest do
  @moduledoc """
  Scheduled work runs through Oban's cron, not Quantum, and the queues are
  separated so trending never starves a paying request (ADR-004 step 6).
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)

  defp production_config do
    env = %{
      "LEI_JWT_SECRET" => "quantum-removed-test",
      "LEI_SESSION_SECRET" => String.duplicate("s", 88),
      "DATABASE_URL" => "ecto://u:p@localhost/db",
      "STRIPE_SECRET_KEY" => "sk_test_" <> String.duplicate("x", 24)
    }

    saved = for {k, _} <- env, into: %{}, do: {k, System.get_env(k)}
    for {k, v} <- env, do: System.put_env(k, v)

    try do
      compile_time =
        Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod, target: :host)

      runtime =
        Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod, target: :host)

      Config.Reader.merge(compile_time, runtime)[:lei_service]
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "production schedules cache cleaning through Oban cron" do
    crontab = production_config()[Oban][:cron][:crontab]
    assert crontab, "no Oban cron configured: nothing schedules cleaning"

    entries = Enum.map(crontab, fn {schedule, worker} -> {schedule, worker} end)
    assert {"*/5 * * * *", LeiService.CacheCleanerWorker} in entries
  end

  test "production reconciles the ledger against Stripe hourly (#139)" do
    # A comparison that is never scheduled reports nothing, and nothing on
    # /metrics would say so until someone noticed runs stayed at 0.
    crontab = production_config()[Oban][:cron][:crontab] || []
    workers = Enum.map(crontab, fn {_schedule, worker} -> worker end)
    assert LeiService.StripeReconciliationWorker in workers
  end

  test "trending is not scheduled: it is parked (#206)" do
    # The code and its routes remain; nothing refreshes them. Re-adding the
    # cron entry turns the most expensive thing we ran back on, so it should
    # be a decision someone makes deliberately, with this test updated.
    crontab = production_config()[Oban][:cron][:crontab] || []
    workers = Enum.map(crontab, fn {_schedule, worker} -> worker end)

    refute LeiService.TrendingScheduleWorker in workers,
           "trending is scheduled again; if that is intended, update this test and #206"
  end

  test "trending has its own queue, at one at a time, from both config sources" do
    # runtime.exs sets :queues too and wins the merge, so a wrong value in
    # either file must fail here -- checking only the merged result lets
    # prod.exs drift unnoticed.
    compile_time =
      Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod, target: :host)[
        :lei_service
      ][Oban][:queues]

    for {source, queues} <- [
          {"prod.exs", compile_time},
          {"merged", production_config()[Oban][:queues]}
        ] do
      assert queues[:trending] == 1,
             "#{source}: a second trending analysis at once is what exhausted memory (#158)"

      assert queues[:maintenance] == 1, "#{source}: no maintenance queue"
      assert queues[:analysis] >= 1, "#{source}: no analysis queue"
    end
  end

  test "Quantum is gone: no dependency, no scheduler, no config" do
    mix_exs = File.read!(Path.join(@root, "apps/lei_service/mix.exs"))
    refute mix_exs =~ "quantum"

    refute File.exists?(Path.join(@root, "apps/lei_service/lib/lei_service/scheduler.ex"))
    refute Code.ensure_loaded?(LeiService.Scheduler)

    for file <- ["config/config.exs", "config/runtime.exs"] do
      refute File.read!(Path.join(@root, file)) =~ "LeiService.Scheduler"
    end

    application = File.read!(Path.join(@root, "apps/lei_service/lib/lei_service/application.ex"))
    refute application =~ "Scheduler"
  end

  test "the operator trigger queues a run rather than spawning one" do
    endpoint = File.read!(Path.join(@root, "apps/lei_service/lib/lei_service/endpoint.ex"))
    refute endpoint =~ "Task.start_link(fn -> LeiService.GithubTrending.process_languages()"
    assert endpoint =~ "TrendingScheduleWorker"
  end
end
