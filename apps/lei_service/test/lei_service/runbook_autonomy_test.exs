defmodule LeiService.RunbookAutonomyTest do
  @moduledoc """
  In a Claude Code session in this repository, the `scripts/payments.sh`
  commands that move money prompt before they run.

  `.claude/settings.json` allows the reading commands and switching a payment
  path off, and asks for everything that moves money. These keep those rules in
  agreement with the script's real subcommands, so a money-moving command can
  never slip into `allow` or out of `ask` unnoticed.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @settings Path.join(@root, ".claude/settings.json")
  @script Path.join(@root, "scripts/payments.sh")

  # Changing these is changing which commands prompt.
  @moves_money ~w(switch-on release refund)
  @agent_may ~w(held ledger reconciliation status switch-off)

  defp settings, do: @settings |> File.read!() |> Poison.decode!()

  defp script_rule_commands(rules) do
    rules
    |> Enum.flat_map(fn rule ->
      case Regex.run(~r/^Bash\(scripts\/payments\.sh ([a-z-]+)/, rule) do
        [_, command] -> [command]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp script_subcommands do
    body = File.read!(@script)
    [_, dispatch] = String.split(body, ~s(case "$command" in), parts: 2)

    Regex.scan(~r/^  ([a-z][a-z-]*(?: \| [a-z][a-z-]*)*)\)/m, dispatch)
    |> Enum.flat_map(fn [_, labels] -> String.split(labels, " | ") end)
    |> Enum.sort()
  end

  test "an agent may run exactly the reading commands and switch-off, unprompted" do
    assert script_rule_commands(settings()["permissions"]["allow"]) == @agent_may
  end

  test "nothing that moves money is allowed, and all of it asks" do
    %{"allow" => allow, "ask" => ask} = settings()["permissions"]

    assert MapSet.disjoint?(MapSet.new(script_rule_commands(allow)), MapSet.new(@moves_money))
    assert MapSet.subset?(MapSet.new(@moves_money), MapSet.new(script_rule_commands(ask)))
  end

  test "the tools underneath the script ask too, so the script cannot be bypassed unprompted" do
    ask = settings()["permissions"]["ask"]

    for rule <- ["flyctl ssh", "flyctl secrets", "flyctl deploy", "stripe post"] do
      assert Enum.any?(ask, &String.starts_with?(&1, "Bash(#{rule}")),
             "#{rule} is not in ask: an agent could do what the script does without the prompt"
    end
  end

  test "every subcommand the script has is deliberately placed" do
    assert script_subcommands() == Enum.sort(@agent_may ++ @moves_money)
  end
end
