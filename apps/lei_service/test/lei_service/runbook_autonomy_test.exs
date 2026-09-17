defmodule LeiService.RunbookAutonomyTest do
  @moduledoc """
  What an agent may do without asking is enforced, and says what it enforces
  (#139).

  The payment runbooks (`.claude/skills/`) are executed by agents. Decided
  2026-09-17, to start: **an agent stops money; it does not move money.** The
  runbooks say so, but a runbook is prose an agent can misread or skip. The
  boundary is enforced by Claude Code's permission rules in
  `.claude/settings.json`: allowed subcommands run unprompted, `ask` prompts the
  operator.

  These keep the three in agreement -- the rules, the script's real
  subcommands, and the autonomy table agents read -- so widening autonomy is a
  deliberate change to both, and a money-moving command can never slip into
  `allow` or out of `ask` unnoticed.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @settings Path.join(@root, ".claude/settings.json")
  @script Path.join(@root, "scripts/payments.sh")
  @skills Path.join(@root, ".claude/skills")

  # Decided 2026-09-17. Changing this is changing the policy.
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

  defp autonomy_table do
    body = File.read!(Path.join(@skills, "payments-operations/SKILL.md"))
    [_, section] = String.split(body, "## Autonomy", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    rows =
      section
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))
      |> Enum.concat(
        section
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "| | `"))
      )

    cells = fn col ->
      rows
      |> Enum.flat_map(fn row ->
        row |> String.split("|") |> Enum.at(col, "") |> then(&Regex.scan(~r/`([a-z-]+)`/, &1))
      end)
      |> Enum.map(fn [_, c] -> c end)
    end

    {cells.(1) |> Enum.uniq() |> Enum.sort(), cells.(2) |> Enum.uniq() |> Enum.sort()}
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

  test "the autonomy table agents read matches the rules that enforce it" do
    {agent_may, needs_approval} = autonomy_table()

    assert agent_may == @agent_may
    assert MapSet.subset?(MapSet.new(@moves_money), MapSet.new(needs_approval))
  end

  test "every payments.sh command a runbook tells an agent to run exists" do
    known = MapSet.new(script_subcommands())

    for skill <- Path.wildcard(Path.join(@skills, "*/SKILL.md")),
        [_, command] <- Regex.scan(~r/scripts\/payments\.sh ([a-z][a-z-]*)/, File.read!(skill)) do
      assert command in known, "#{Path.relative_to(skill, @root)} runs unknown `#{command}`"
    end
  end

  test "every runbook skill has a name and a description an agent can match on" do
    skills = Path.wildcard(Path.join(@skills, "*/SKILL.md"))
    assert length(skills) >= 7

    for skill <- skills do
      body = File.read!(skill)
      dir = skill |> Path.dirname() |> Path.basename()
      assert body =~ ~r/\A---\nname: #{dir}\ndescription: .{40,}\n---\n/, "#{dir}: frontmatter"
    end
  end
end
