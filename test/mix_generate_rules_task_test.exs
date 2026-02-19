# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.GenerateRulesTaskTest do
  use ExUnit.Case, async: false

  setup do
    # Run in a temp directory to avoid polluting the project
    tmp_dir = Path.join(System.tmp_dir!(), "lei-rules-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    original_dir = File.cwd!()
    File.cd!(tmp_dir)

    on_exit(fn ->
      File.cd!(original_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "generates cursor rules file", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Lei.GenerateRules.run(["--target", "cursor"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "Generated"
    assert File.exists?(Path.join(tmp_dir, ".cursor/rules/lei-dependency-rules.mdc"))
  end

  test "generates copilot rules file", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Lei.GenerateRules.run(["--target", "copilot"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "Generated"
    assert File.exists?(Path.join(tmp_dir, ".github/instructions/lei-dependency-rules.instructions.md"))
  end

  test "generates all targets by default", %{tmp_dir: tmp_dir} do
    Mix.Tasks.Lei.GenerateRules.run([])
    assert_received {:mix_shell, :info, [cursor_msg]}
    assert cursor_msg =~ "Generated"
    assert_received {:mix_shell, :info, [copilot_msg]}
    assert copilot_msg =~ "Generated"

    assert File.exists?(Path.join(tmp_dir, ".cursor/rules/lei-dependency-rules.mdc"))
    assert File.exists?(Path.join(tmp_dir, ".github/instructions/lei-dependency-rules.instructions.md"))
  end

  test "build_thresholds uses opts when provided" do
    thresholds = Mix.Tasks.Lei.GenerateRules.build_thresholds(
      contributor_critical: 10,
      currency_critical: 200
    )

    assert thresholds.contributor_critical == 10
    assert thresholds.currency_critical == 200
  end

  test "raises for invalid target" do
    assert_raise Mix.Error, ~r/Invalid target/, fn ->
      Mix.Tasks.Lei.GenerateRules.run(["--target", "invalid"])
    end
  end

  test "build_thresholds uses defaults when no opts" do
    thresholds = Mix.Tasks.Lei.GenerateRules.build_thresholds([])

    # Should use app config or defaults
    assert is_number(thresholds.contributor_critical)
    assert is_number(thresholds.currency_critical)
    assert is_number(thresholds.large_commit_critical)
  end
end
