defmodule LeiService.QueueHealthWiringTest do
  @moduledoc """
  The queue check is wired into readiness and metrics in production.

  A check nothing calls reports nothing. The monitor already fails on a
  "degraded" readiness, so registering the check is what makes stuck work
  alert.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../../config", __DIR__)

  defp production_config do
    env = %{
      "LEI_JWT_SECRET" => "queue-health-test-jwt",
      "LEI_SESSION_SECRET" => String.duplicate("s", 88),
      "DATABASE_URL" => "ecto://u:p@localhost/db",
      "STRIPE_SECRET_KEY" => "sk_test_" <> String.duplicate("x", 24)
    }

    saved = for {k, _} <- env, into: %{}, do: {k, System.get_env(k)}
    for {k, v} <- env, do: System.put_env(k, v)

    try do
      compile_time =
        Config.Reader.read!(Path.join(@root, "config.exs"), env: :prod, target: :host)

      runtime = Config.Reader.read!(Path.join(@root, "runtime.exs"), env: :prod, target: :host)
      Config.Reader.merge(compile_time, runtime)[:lei_service]
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "readiness runs the queue check in production" do
    checks = production_config()[:optional_health_checks]
    assert checks, "no optional health checks configured; this test checked nothing"
    assert checks[:queue] == {LeiService.QueueHealth, :status, []}
  end

  test "metrics include the queue collector in production" do
    assert {LeiService.QueueHealth, :metrics, []} in production_config()[:metrics_collectors]
  end

  test "the stuck threshold is longer than Lifeline's rescue window" do
    config = production_config()
    {rescue_after, :minutes} = config[Oban][:lifeline][:rescue_after]
    stuck_after = config[:queue_health][:stuck_after_minutes]

    assert stuck_after > rescue_after,
           "a job Lifeline would still rescue (#{rescue_after}m) would be reported stuck at #{stuck_after}m"
  end

  describe "the monitor's readiness probe" do
    @readiness Path.expand("../../../../scripts/ops/check-readiness.sh", __DIR__)

    defp readiness(body) do
      bin = Path.join(System.tmp_dir!(), "readyz-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf!(bin) end)
      File.write!(Path.join(bin, "body"), body)
      File.write!(Path.join(bin, "curl"), "#!/usr/bin/env bash\ncat #{bin}/body\n")
      File.chmod!(Path.join(bin, "curl"), 0o755)

      System.cmd("bash", [@readiness, "https://example.test"],
        env: [{"PATH", "#{bin}:#{System.get_env("PATH")}"}],
        stderr_to_stdout: true
      )
    end

    test "fails on degraded, naming the dependency" do
      {out, code} =
        readiness(~s({"status":"degraded","checks":{"redis":"down","database":"ok"}}))

      assert code == 1
      assert out =~ "DEGRADED. Failing dependencies: redis."
    end

    test "fails when nothing answers" do
      {out, 1} = readiness("")
      assert out =~ "'unreachable'"
    end

    test "passes when every dependency is ok" do
      {_out, 0} = readiness(~s({"status":"ok","checks":{"redis":"ok"}}))
    end

    test "is what the monitor runs" do
      assert monitor() =~ "scripts/ops/check-readiness.sh https://lowendinsight.dev"
    end
  end

  test "the monitor reports the queue gauges and fails when it cannot read them" do
    monitor = monitor()
    assert monitor =~ "grep '^lei_queue'"
    assert monitor =~ "lei_queue_error 1"
    assert monitor =~ ~r/no queue gauges/
  end

  defp monitor, do: File.read!(Path.expand("../../../../.github/workflows/monitor.yml", __DIR__))
end
