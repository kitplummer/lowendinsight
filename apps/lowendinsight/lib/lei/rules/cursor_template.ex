# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Rules.CursorTemplate do
  @moduledoc """
  Renders the Cursor IDE rule file (.mdc) for LowEndInsight dependency risk awareness.
  """

  @doc """
  Renders the Cursor rules template with the given threshold values.
  """
  @spec render(map()) :: String.t()
  def render(thresholds) do
    """
    ---
    description: LowEndInsight dependency bus-factor risk guidelines
    globs:
      - mix.exs
      - mix.lock
      - package.json
      - package-lock.json
      - yarn.lock
      - requirements.txt
      - Gemfile
      - go.mod
      - Cargo.toml
    ---

    # LowEndInsight Dependency Risk Rules

    When adding, updating, or reviewing dependencies, assess bus-factor risk using
    the LowEndInsight criteria below. Flag dependencies that meet **high** or
    **critical** thresholds and suggest mitigation or alternatives.

    ## Risk Metrics and Thresholds

    ### Contributor Count
    Total number of unique contributors to the dependency repository.
    - **critical**: fewer than #{thresholds.contributor_critical} contributors
    - **high**: #{thresholds.contributor_critical} to #{thresholds.contributor_high - 1} contributors
    - **medium**: #{thresholds.contributor_high} to #{thresholds.contributor_medium - 1} contributors
    - **low**: #{thresholds.contributor_medium} or more contributors

    ### Functional Contributors
    Contributors responsible for the majority of meaningful commits (bus-factor core).
    - **critical**: fewer than #{thresholds.functional_critical} functional contributors
    - **high**: #{thresholds.functional_critical} to #{thresholds.functional_high - 1} functional contributors
    - **medium**: #{thresholds.functional_high} to #{thresholds.functional_medium - 1} functional contributors
    - **low**: #{thresholds.functional_medium} or more functional contributors

    ### Commit Currency
    How recently the dependency was actively maintained, measured in weeks since last commit.
    - **low**: fewer than #{thresholds.currency_medium} weeks since last commit
    - **medium**: #{thresholds.currency_medium} to #{thresholds.currency_high - 1} weeks
    - **high**: #{thresholds.currency_high} to #{thresholds.currency_critical - 1} weeks
    - **critical**: #{thresholds.currency_critical} or more weeks since last commit

    ### Large Recent Commit Size
    Percentage of codebase changed in the most recent commit (volatility indicator).
    - **low**: less than #{format_percent(thresholds.large_commit_medium)} of codebase changed
    - **medium**: #{format_percent(thresholds.large_commit_medium)} to #{format_percent(thresholds.large_commit_high)} of codebase
    - **high**: #{format_percent(thresholds.large_commit_high)} to #{format_percent(thresholds.large_commit_critical)} of codebase
    - **critical**: #{format_percent(thresholds.large_commit_critical)} or more of codebase changed

    ## Instructions

    1. When a new dependency is being added to the project, warn if it is likely to
       have a **high** or **critical** bus-factor risk based on the thresholds above.
       Common indicators: single-maintainer projects, repositories with no commits in
       over #{thresholds.currency_high} weeks, or projects with fewer than
       #{thresholds.contributor_medium} contributors.

    2. When reviewing code that adds or updates dependencies, check:
       - Does the dependency have an SBOM (bom.xml or .spdx file)?
       - Is there more than one active functional contributor?
       - Has the project been committed to within the last #{thresholds.currency_medium} weeks?

    3. For any dependency flagged as **critical** risk, suggest:
       - Evaluating alternative packages with healthier contributor profiles
       - Vendoring or forking the dependency if no alternative exists
       - Running `mix lei.scan` to get a full LowEndInsight risk report

    4. For dependencies flagged as **high** risk, suggest:
       - Monitoring the dependency for maintenance activity
       - Running `mix lei.analyze <repo_url>` for detailed analysis

    ## Running LowEndInsight

    - `mix lei.scan` — Scan all dependencies in the current project
    - `mix lei.analyze <url>` — Analyze a single repository by URL
    - `mix lei.dependencies` — List all transitive dependencies
    """
  end

  defp format_percent(value) when is_float(value) do
    "#{round(value * 100)}%"
  end
end
