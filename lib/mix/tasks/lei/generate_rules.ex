# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Mix.Tasks.Lei.GenerateRules do
  @shortdoc "Generate static AI assistant rule files for dependency risk awareness"
  @moduledoc ~S"""
  Generates static context/rule files that inject LowEndInsight dependency risk
  awareness into AI coding assistants.

  Supported targets:
  - **Cursor IDE**: `.cursor/rules/lei-dependency-rules.mdc`
  - **GitHub Copilot**: `.github/instructions/lei-dependency-rules.instructions.md`

  ## Usage

      mix lei.generate_rules

  Generates rule files for all supported targets using default thresholds.

      mix lei.generate_rules --target cursor
      mix lei.generate_rules --target copilot

  Generates rule files for a specific target only.

      mix lei.generate_rules --contributor-critical 3 --currency-critical 156

  Override default risk thresholds for the generated rules.

  ## Options

  - `--target` - Generate rules for a specific target: `cursor`, `copilot`, or `all` (default: `all`)
  - `--contributor-critical` - Critical threshold for contributor count (default: from app config or `2`)
  - `--contributor-high` - High threshold for contributor count (default: from app config or `3`)
  - `--contributor-medium` - Medium threshold for contributor count (default: from app config or `5`)
  - `--currency-critical` - Critical threshold for commit currency in weeks (default: from app config or `104`)
  - `--currency-high` - High threshold for commit currency in weeks (default: from app config or `52`)
  - `--currency-medium` - Medium threshold for commit currency in weeks (default: from app config or `26`)
  - `--functional-critical` - Critical threshold for functional contributors (default: from app config or `2`)
  - `--functional-high` - High threshold for functional contributors (default: from app config or `3`)
  - `--functional-medium` - Medium threshold for functional contributors (default: from app config or `5`)
  - `--large-commit-critical` - Critical threshold for large commit percentage (default: from app config or `0.40`)
  - `--large-commit-high` - High threshold for large commit percentage (default: from app config or `0.30`)
  - `--large-commit-medium` - Medium threshold for large commit percentage (default: from app config or `0.20`)
  """

  use Mix.Task

  @targets ~w(cursor copilot all)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          target: :string,
          contributor_critical: :integer,
          contributor_high: :integer,
          contributor_medium: :integer,
          currency_critical: :integer,
          currency_high: :integer,
          currency_medium: :integer,
          functional_critical: :integer,
          functional_high: :integer,
          functional_medium: :integer,
          large_commit_critical: :float,
          large_commit_high: :float,
          large_commit_medium: :float
        ]
      )

    target = Keyword.get(opts, :target, "all")

    unless target in @targets do
      Mix.raise("Invalid target: #{target}. Must be one of: #{Enum.join(@targets, ", ")}")
    end

    thresholds = build_thresholds(opts)

    case target do
      "cursor" -> generate_cursor(thresholds)
      "copilot" -> generate_copilot(thresholds)
      "all" -> generate_all(thresholds)
    end
  end

  defp generate_all(thresholds) do
    generate_cursor(thresholds)
    generate_copilot(thresholds)
  end

  defp generate_cursor(thresholds) do
    path = ".cursor/rules/lei-dependency-rules.mdc"
    content = Lei.Rules.CursorTemplate.render(thresholds)
    write_file(path, content)
  end

  defp generate_copilot(thresholds) do
    path = ".github/instructions/lei-dependency-rules.instructions.md"
    content = Lei.Rules.CopilotTemplate.render(thresholds)
    write_file(path, content)
  end

  defp write_file(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    Mix.shell().info("Generated #{path}")
  end

  @doc false
  def build_thresholds(opts) do
    %{
      contributor_critical: opt_or_config(opts, :contributor_critical, :critical_contributor_level, 2),
      contributor_high: opt_or_config(opts, :contributor_high, :high_contributor_level, 3),
      contributor_medium: opt_or_config(opts, :contributor_medium, :medium_contributor_level, 5),
      currency_critical: opt_or_config(opts, :currency_critical, :critical_currency_level, 104),
      currency_high: opt_or_config(opts, :currency_high, :high_currency_level, 52),
      currency_medium: opt_or_config(opts, :currency_medium, :medium_currency_level, 26),
      functional_critical: opt_or_config(opts, :functional_critical, :critical_functional_contributors_level, 2),
      functional_high: opt_or_config(opts, :functional_high, :high_functional_contributors_level, 3),
      functional_medium: opt_or_config(opts, :functional_medium, :medium_functional_contributors_level, 5),
      large_commit_critical: opt_or_config(opts, :large_commit_critical, :critical_large_commit_level, 0.40),
      large_commit_high: opt_or_config(opts, :large_commit_high, :high_large_commit_level, 0.30),
      large_commit_medium: opt_or_config(opts, :large_commit_medium, :medium_large_commit_level, 0.20)
    }
  end

  defp opt_or_config(opts, opt_key, config_key, default) do
    case Keyword.fetch(opts, opt_key) do
      {:ok, value} -> value
      :error ->
        case Application.fetch_env(:lowendinsight, config_key) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end
end
