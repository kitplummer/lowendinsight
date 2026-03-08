defmodule Lei.AgenticDetectorTest do
  use ExUnit.Case, async: true

  alias Lei.AgenticDetector

  describe "classify_contributor/2" do
    test "classifies dependabot as bot by email" do
      assert AgenticDetector.classify_contributor("dependabot[bot]", "dependabot@github.com") ==
               :bot
    end

    test "classifies renovate as bot by email" do
      assert AgenticDetector.classify_contributor(
               "Renovate Bot",
               "renovate@whitesourcesoftware.com"
             ) ==
               :bot
    end

    test "classifies github-actions as bot by name" do
      assert AgenticDetector.classify_contributor("github-actions[bot]", "noreply@example.com") ==
               :bot
    end

    test "classifies bot by github noreply email pattern" do
      assert AgenticDetector.classify_contributor(
               "some-bot",
               "some-bot[bot]@users.noreply.github.com"
             ) == :bot
    end

    test "classifies snyk-bot by email" do
      assert AgenticDetector.classify_contributor("Snyk", "snyk-bot@snyk.io") == :bot
    end

    test "classifies mergify by name" do
      assert AgenticDetector.classify_contributor("mergify", "merge@example.com") == :bot
    end

    test "classifies imgbot by name" do
      assert AgenticDetector.classify_contributor("imgbot", "img@example.com") == :bot
    end

    test "classifies semantic-release-bot by name" do
      assert AgenticDetector.classify_contributor("semantic-release-bot", "release@example.com") ==
               :bot
    end

    test "classifies release-please by email" do
      assert AgenticDetector.classify_contributor(
               "Release Please",
               "release-please@google.com"
             ) == :bot
    end

    test "classifies normal contributor as human" do
      assert AgenticDetector.classify_contributor("Jane Doe", "jane@example.com") == :human
    end

    test "classifies contributor with bot-like but non-matching name as human" do
      assert AgenticDetector.classify_contributor("robotfan", "robot@example.com") == :human
    end
  end

  describe "detect_ai_coauthors/1" do
    test "detects Claude co-author trailer" do
      messages = ["feat: add feature\n\nCo-Authored-By: Claude <noreply@anthropic.com>"]
      result = AgenticDetector.detect_ai_coauthors(messages)
      assert length(result) > 0
      assert Enum.any?(result, &String.contains?(&1, "Claude"))
    end

    test "detects Copilot co-author trailer" do
      messages = ["fix: bug\n\nCo-Authored-By: GitHub Copilot <copilot@github.com>"]
      result = AgenticDetector.detect_ai_coauthors(messages)
      assert length(result) > 0
    end

    test "detects Cursor co-author trailer" do
      messages = ["refactor: cleanup\n\nCo-Authored-By: Cursor AI <cursor@cursor.com>"]
      result = AgenticDetector.detect_ai_coauthors(messages)
      assert length(result) > 0
    end

    test "returns empty list for normal commits" do
      messages = ["feat: normal feature", "fix: normal bug fix"]
      assert AgenticDetector.detect_ai_coauthors(messages) == []
    end

    test "deduplicates across messages" do
      messages = [
        "feat: one\n\nCo-Authored-By: Claude <noreply@anthropic.com>",
        "feat: two\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
      ]

      result = AgenticDetector.detect_ai_coauthors(messages)
      assert length(result) == 1
    end

    test "returns empty list for empty input" do
      assert AgenticDetector.detect_ai_coauthors([]) == []
    end
  end

  describe "analyze/2" do
    test "analyzes mixed contributors" do
      contributors_with_messages = [
        {%{name: "Jane Doe", email: "jane@example.com", count: 50}, ["feat: add stuff"]},
        {%{name: "dependabot[bot]", email: "dependabot@github.com", count: 20},
         ["chore: bump deps"]},
        {%{name: "Bob Smith", email: "bob@example.com", count: 30},
         ["fix: thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>"]}
      ]

      result = AgenticDetector.analyze(contributors_with_messages, 3)

      assert result.human_contributor_count == 1
      assert length(result.bot_contributors) == 1
      assert "dependabot[bot]" in result.bot_contributors
      assert length(result.agent_contributors) == 1
      assert "Bob Smith" in result.agent_contributors
      assert result.agentic_contribution_ratio == 0.5
      assert result.human_functional_contributors == 2
    end

    test "analyzes all-human contributors" do
      contributors_with_messages = [
        {%{name: "Jane", email: "jane@example.com", count: 10}, ["feat: one"]},
        {%{name: "Bob", email: "bob@example.com", count: 10}, ["feat: two"]}
      ]

      result = AgenticDetector.analyze(contributors_with_messages, 2)

      assert result.human_contributor_count == 2
      assert result.bot_contributors == []
      assert result.agent_contributors == []
      assert result.agentic_contribution_ratio == 0.0
    end

    test "handles empty contributor list" do
      result = AgenticDetector.analyze([], 0)

      assert result.human_contributor_count == 0
      assert result.bot_contributors == []
      assert result.agent_contributors == []
      assert result.agentic_contribution_ratio == 0.0
      assert result.classified_contributors == []
    end

    test "bot commits count toward agentic ratio" do
      contributors_with_messages = [
        {%{name: "dependabot[bot]", email: "dependabot@github.com", count: 100}, ["chore: bump"]}
      ]

      result = AgenticDetector.analyze(contributors_with_messages, 0)
      assert result.agentic_contribution_ratio == 1.0
    end
  end
end
