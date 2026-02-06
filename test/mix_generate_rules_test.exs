# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule MixGenerateRulesTest do
  use ExUnit.Case, async: true

  @default_thresholds %{
    contributor_critical: 2,
    contributor_high: 3,
    contributor_medium: 5,
    currency_critical: 104,
    currency_high: 52,
    currency_medium: 26,
    functional_critical: 2,
    functional_high: 3,
    functional_medium: 5,
    large_commit_critical: 0.40,
    large_commit_high: 0.30,
    large_commit_medium: 0.20
  }

  describe "build_thresholds/1" do
    test "uses defaults when no opts provided" do
      thresholds = Mix.Tasks.Lei.GenerateRules.build_thresholds([])

      assert thresholds.contributor_critical == 2
      assert thresholds.contributor_high == 3
      assert thresholds.contributor_medium == 5
      assert thresholds.currency_critical == 104
      assert thresholds.currency_high == 52
      assert thresholds.currency_medium == 26
    end

    test "overrides with CLI options" do
      opts = [contributor_critical: 4, currency_critical: 156]
      thresholds = Mix.Tasks.Lei.GenerateRules.build_thresholds(opts)

      assert thresholds.contributor_critical == 4
      assert thresholds.currency_critical == 156
      # non-overridden values remain default
      assert thresholds.contributor_high == 3
    end
  end

  describe "CursorTemplate.render/1" do
    test "renders valid .mdc content with frontmatter" do
      content = Lei.Rules.CursorTemplate.render(@default_thresholds)

      assert content =~ "---"
      assert content =~ "description: LowEndInsight dependency bus-factor risk guidelines"
      assert content =~ "globs:"
      assert content =~ "mix.exs"
    end

    test "includes threshold values in content" do
      content = Lei.Rules.CursorTemplate.render(@default_thresholds)

      assert content =~ "fewer than 2 contributors"
      assert content =~ "104 or more weeks since last commit"
      assert content =~ "20%"
      assert content =~ "40%"
    end

    test "reflects custom thresholds" do
      custom = %{@default_thresholds | contributor_critical: 4, currency_critical: 200}
      content = Lei.Rules.CursorTemplate.render(custom)

      assert content =~ "fewer than 4 contributors"
      assert content =~ "200 or more weeks since last commit"
    end

    test "includes LowEndInsight commands" do
      content = Lei.Rules.CursorTemplate.render(@default_thresholds)

      assert content =~ "mix lei.scan"
      assert content =~ "mix lei.analyze"
      assert content =~ "mix lei.dependencies"
    end
  end

  describe "CopilotTemplate.render/1" do
    test "renders valid instructions content with frontmatter" do
      content = Lei.Rules.CopilotTemplate.render(@default_thresholds)

      assert content =~ "---"
      assert content =~ "applyTo:"
      assert content =~ "mix.exs"
    end

    test "includes threshold values in content" do
      content = Lei.Rules.CopilotTemplate.render(@default_thresholds)

      assert content =~ "fewer than 2 contributors"
      assert content =~ "104 or more weeks since last commit"
      assert content =~ "20%"
      assert content =~ "40%"
    end

    test "reflects custom thresholds" do
      custom = %{@default_thresholds | functional_critical: 5, currency_medium: 13}
      content = Lei.Rules.CopilotTemplate.render(custom)

      assert content =~ "fewer than 5 functional contributors"
      assert content =~ "fewer than 13 weeks since last commit"
    end
  end

  describe "mix lei.generate_rules task" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "lei_rules_test_#{:erlang.unique_integer([:positive])}")
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

      path = Path.join(tmp_dir, ".cursor/rules/lei-dependency-rules.mdc")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "LowEndInsight"
      assert content =~ "globs:"
    end

    test "generates copilot instructions file", %{tmp_dir: tmp_dir} do
      Mix.Tasks.Lei.GenerateRules.run(["--target", "copilot"])

      path = Path.join(tmp_dir, ".github/instructions/lei-dependency-rules.instructions.md")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "LowEndInsight"
      assert content =~ "applyTo:"
    end

    test "generates all targets by default", %{tmp_dir: tmp_dir} do
      Mix.Tasks.Lei.GenerateRules.run([])

      assert File.exists?(Path.join(tmp_dir, ".cursor/rules/lei-dependency-rules.mdc"))
      assert File.exists?(Path.join(tmp_dir, ".github/instructions/lei-dependency-rules.instructions.md"))
    end

    test "accepts custom threshold options", %{tmp_dir: tmp_dir} do
      Mix.Tasks.Lei.GenerateRules.run([
        "--target", "cursor",
        "--contributor-critical", "4",
        "--currency-critical", "200"
      ])

      path = Path.join(tmp_dir, ".cursor/rules/lei-dependency-rules.mdc")
      content = File.read!(path)

      assert content =~ "fewer than 4 contributors"
      assert content =~ "200 or more weeks since last commit"
    end
  end
end
