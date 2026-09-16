defmodule LeiService.ObanProductionConfigTest do
  @moduledoc """
  Production's Oban runs Lifeline and Pruner.

  Oban starts no plugins unless configured, and production configured none.
  A job executing when a deploy stopped the node stayed `executing` forever,
  its analysis never finished and nothing retried it: 79 such jobs from
  2026-09-10..14 were found. Test config disables plugins, so only reading
  the production configuration shows this.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../../config", __DIR__)

  defp production_oban_config do
    env = %{
      "LEI_JWT_SECRET" => "oban-config-test-jwt",
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
      Config.Reader.merge(compile_time, runtime)[:lei_service][Oban]
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "Lifeline rescues orphaned jobs, after longer than an analysis runs" do
    oban = production_oban_config()
    assert oban, "no Oban configuration for production; this test checked nothing"

    assert lifeline = oban[:lifeline],
           "production Oban has no Lifeline: orphaned jobs stay executing"

    {n, unit} = Keyword.fetch!(lifeline, :rescue_after)
    minutes = %{minutes: 1, minute: 1, hours: 60, hour: 60}[unit] * n
    assert minutes >= 30, "rescue_after #{n} #{unit} would re-run analyses that are still running"
    refute oban[:plugins] == false
  end

  test "Pruner removes finished jobs" do
    assert Keyword.has_key?(production_oban_config()[:pruner] || [], :max_age)
  end
end
