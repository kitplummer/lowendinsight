defmodule LeiService.CanaryKillSwitchTest do
  @moduledoc """
  A deploy while stablecoin is switched off does not fail the canary and roll
  itself back (#139).

  The canary checks that a 402 offers stablecoin. With `tempo` switched off it
  cannot, and before this the deploy gate would roll back every release made
  during the incident -- including the one shipping the fix. The canary now
  skips that check when `/metrics` reports the switch off, and only then.

  These run the canary's own `sed` against what `Lei.Metrics` actually emits,
  so a renamed metric, which would silently stop the canary seeing the switch,
  fails here rather than in a rolled-back deploy.
  """
  use ExUnit.Case, async: false

  alias Lei.Payments.Switches

  @canary File.read!(Path.expand("../../../../scripts/canary.sh", __DIR__))

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  # The expression the canary uses to read the tempo switch from /metrics.
  defp canary_switch_reader do
    [_, expression] =
      Regex.run(~r/TEMPO_SWITCH=\$\(curl[^\n]*\n\s*\| sed -n '([^']+)'\)/, @canary)

    expression
  end

  defp run_reader(body) do
    path = Path.join(System.tmp_dir!(), "canary-metrics-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    {out, 0} = System.cmd("sed", ["-n", canary_switch_reader(), path])
    File.rm!(path)
    String.trim(out)
  end

  test "reads 1 from the metrics the service emits while tempo is on" do
    assert run_reader(Lei.Metrics.collect()) == "1"
  end

  test "reads 0 from the metrics the service emits once tempo is switched off" do
    {:ok, _} = Switches.set("tempo", false, "canary test", "test")
    assert run_reader(Lei.Metrics.collect()) == "0"
  end

  test "reads nothing when the metric is absent, and only 0 skips the check" do
    assert run_reader("lei_payment_switch_enabled{path=\"acp\"} 0\n") == ""
    assert @canary =~ ~s(if [ "$TEMPO_SWITCH" = "0" ]; then)
  end
end
