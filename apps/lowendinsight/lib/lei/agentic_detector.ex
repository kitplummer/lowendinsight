defmodule Lei.AgenticDetector do
  @moduledoc """
  Classifies contributors as human, bot, or AI-assisted (agent)
  based on email/name patterns and commit message trailers.
  """

  @bot_email_patterns [
    ~r/\[bot\]@users\.noreply\.github\.com$/i,
    ~r/^dependabot@/i,
    ~r/^renovate@/i,
    ~r/^greenkeeper@/i,
    ~r/^snyk-bot@/i,
    ~r/^github-actions@/i,
    ~r/^mergify@/i,
    ~r/^imgbot@/i,
    ~r/^semantic-release-bot@/i,
    ~r/^release-please@/i
  ]

  @bot_name_patterns [
    ~r/\[bot\]$/i,
    ~r/^dependabot$/i,
    ~r/^renovate$/i,
    ~r/^github-actions$/i,
    ~r/^mergify$/i,
    ~r/^imgbot$/i,
    ~r/^semantic-release-bot$/i,
    ~r/^release-please$/i
  ]

  @default_mixed_threshold 0.3
  @default_agent_threshold 0.7

  @deprecated_env_vars ~w[LEI_CRITICAL_AGENTIC_LEVEL LEI_HIGH_AGENTIC_LEVEL LEI_MEDIUM_AGENTIC_LEVEL]

  @ai_coauthor_patterns [
    ~r/Co-Authored-By:.*Claude/i,
    ~r/Co-Authored-By:.*@anthropic\.com/i,
    ~r/Co-Authored-By:.*Copilot/i,
    ~r/Co-Authored-By:.*Cursor/i,
    ~r/Co-Authored-By:.*Windsurf/i,
    ~r/Co-Authored-By:.*Devin/i
  ]

  @doc """
  Classifies a contributor as `:human` or `:bot` based on name/email patterns.
  """
  @spec classify_contributor(String.t(), String.t()) :: :human | :bot
  def classify_contributor(name, email) do
    if bot_by_email?(email) or bot_by_name?(name) do
      :bot
    else
      :human
    end
  end

  @doc """
  Detects AI co-author trailers in commit messages.
  Returns a deduplicated list of matched AI tool names.
  """
  @spec detect_ai_coauthors([String.t()]) :: [String.t()]
  def detect_ai_coauthors(commit_messages) do
    commit_messages
    |> Enum.flat_map(&extract_ai_coauthors/1)
    |> Enum.uniq()
  end

  @doc """
  Classifies an agentic contribution ratio into a human/mixed/agent label.

  Thresholds are controlled by env vars:
    - `LEI_AGENTIC_MIXED_THRESHOLD` (default #{@default_mixed_threshold}): lower boundary for "mixed"
    - `LEI_AGENTIC_AGENT_THRESHOLD` (default #{@default_agent_threshold}): lower boundary for "agent"

  Boundaries:
    - ratio < mixed_threshold → "human"
    - mixed_threshold ≤ ratio ≤ agent_threshold → "mixed"
    - ratio > agent_threshold → "agent"

  Deprecated env vars `LEI_CRITICAL_AGENTIC_LEVEL`, `LEI_HIGH_AGENTIC_LEVEL`, and
  `LEI_MEDIUM_AGENTIC_LEVEL` are no longer used; a warning is logged if they are set.
  """
  @spec classify_ratio(float()) :: {:ok, String.t()}
  def classify_ratio(ratio) do
    warn_deprecated_env_vars()
    mixed_threshold = get_threshold("LEI_AGENTIC_MIXED_THRESHOLD", @default_mixed_threshold)
    agent_threshold = get_threshold("LEI_AGENTIC_AGENT_THRESHOLD", @default_agent_threshold)

    cond do
      ratio > agent_threshold -> {:ok, "agent"}
      ratio >= mixed_threshold -> {:ok, "mixed"}
      true -> {:ok, "human"}
    end
  end

  @doc """
  Analyzes a list of contributors with their commit messages.

  Expects a list of `{contributor, commit_messages}` tuples where
  contributor is a map/struct with `:name`, `:email`, `:count` fields,
  and commit_messages is a list of commit body strings.

  Returns analysis summary with classified contributors and metrics.
  """
  @spec analyze([{map(), [String.t()]}], non_neg_integer()) :: map()
  def analyze(contributors_with_messages, functional_count) do
    classified =
      Enum.map(contributors_with_messages, fn {contributor, messages} ->
        base_class = classify_contributor(contributor.name, contributor.email)
        ai_coauthors = detect_ai_coauthors(messages)

        classification =
          case {base_class, ai_coauthors} do
            {:bot, _} -> :bot
            {:human, [_ | _]} -> :agent
            {:human, []} -> :human
          end

        %{
          name: contributor.name,
          email: contributor.email,
          commit_count: contributor.count,
          classification: classification,
          ai_coauthors: ai_coauthors
        }
      end)

    human_contributors = Enum.filter(classified, &(&1.classification == :human))
    bot_contributors = Enum.filter(classified, &(&1.classification == :bot))
    agent_contributors = Enum.filter(classified, &(&1.classification == :agent))

    total_commits = Enum.reduce(classified, 0, fn c, acc -> acc + c.commit_count end)

    non_human_commits =
      classified
      |> Enum.filter(&(&1.classification in [:bot, :agent]))
      |> Enum.reduce(0, fn c, acc -> acc + c.commit_count end)

    ratio = if total_commits > 0, do: Float.round(non_human_commits / total_commits, 4), else: 0.0

    human_functional =
      if functional_count > 0 do
        max(0, functional_count - length(bot_contributors))
      else
        length(human_contributors)
      end

    %{
      classified_contributors: classified,
      agentic_contribution_ratio: ratio,
      human_contributor_count: length(human_contributors),
      human_functional_contributors: human_functional,
      bot_contributors: Enum.map(bot_contributors, & &1.name),
      agent_contributors: Enum.map(agent_contributors, & &1.name)
    }
  end

  defp get_threshold(env_var, default) do
    case System.get_env(env_var) do
      nil ->
        default

      val ->
        case Float.parse(val) do
          {f, _} -> f
          :error -> default
        end
    end
  end

  defp warn_deprecated_env_vars do
    Enum.each(@deprecated_env_vars, fn var ->
      if System.get_env(var) do
        require Logger

        Logger.warning(
          "[DEPRECATED] Environment variable #{var} is no longer used by Lei.AgenticDetector. " <>
            "Use LEI_AGENTIC_MIXED_THRESHOLD and LEI_AGENTIC_AGENT_THRESHOLD instead."
        )
      end
    end)
  end

  defp bot_by_email?(email) do
    Enum.any?(@bot_email_patterns, &Regex.match?(&1, email))
  end

  defp bot_by_name?(name) do
    Enum.any?(@bot_name_patterns, &Regex.match?(&1, name))
  end

  defp extract_ai_coauthors(message) do
    @ai_coauthor_patterns
    |> Enum.filter(&Regex.match?(&1, message))
    |> Enum.map(fn pattern ->
      case Regex.run(~r/Co-Authored-By:\s*(.+)/i, message) do
        [_, match] -> String.trim(match)
        _ -> Regex.source(pattern)
      end
    end)
  end
end
