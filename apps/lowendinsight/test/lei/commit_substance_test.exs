defmodule Lei.CommitSubstanceTest do
  @moduledoc """
  Which commits count as evidence that a project is being maintained (#244).

  Commit currency was resettable by anything that produced a commit, so a
  repository kept warm by Dependabot and README fixes reported the same
  currency as one under active development. Because that holds at every
  threshold, the levels could not be tightened into catching it -- the signal
  had to change, not the dial.

  The cases below are the ones that made the old metric wrong in practice.
  """
  use ExUnit.Case, async: true

  alias Lei.CommitSubstance

  defp commit(opts) do
    %{
      sha: "abc",
      date: "2026-01-01T00:00:00Z",
      author_name: Keyword.get(opts, :name, "Ada Lovelace"),
      author_email: Keyword.get(opts, :email, "ada@example.com"),
      files: Keyword.get(opts, :files, ["lib/thing.ex"])
    }
  end

  describe "automation does not count as attention" do
    test "a dependabot bump is not substantive, whatever it touches" do
      refute CommitSubstance.substantive?(
               commit(
                 name: "dependabot[bot]",
                 email: "49699333+dependabot[bot]@users.noreply.github.com",
                 files: ["mix.lock", "lib/real_code.ex"]
               )
             )
    end

    for {name, email} <- [
          {"renovate[bot]", "renovate@whitesourcesoftware.com"},
          {"github-actions[bot]", "github-actions@github.com"},
          {"release-please[bot]", "release-please@users.noreply.github.com"}
        ] do
      test "#{name} is not substantive" do
        refute CommitSubstance.substantive?(
                 commit(name: unquote(name), email: unquote(email), files: ["lib/a.ex"])
               )
      end
    end
  end

  describe "documentation does not count as attention" do
    test "a README-only commit is not substantive" do
      refute CommitSubstance.substantive?(commit(files: ["README.md"]))
    end

    test "a license year bump is not substantive" do
      refute CommitSubstance.substantive?(commit(files: ["LICENSE"]))
    end

    test "docs and code together is substantive" do
      # The point is whether any work happened, not whether docs were included.
      assert CommitSubstance.substantive?(commit(files: ["README.md", "lib/thing.ex"]))
    end

    test "a whole directory of docs is still only docs" do
      refute CommitSubstance.substantive?(
               commit(files: ["docs/guide.md", "docs/api.md", ".github/workflows/ci.yml"])
             )
    end
  end

  describe "what does count" do
    test "an ordinary code change by a person" do
      assert CommitSubstance.substantive?(commit(files: ["lib/thing.ex"]))
    end

    test "a lockfile bump by a person is substantive" do
      # A human choosing to bump a dependency is a maintenance decision. Only
      # the bot doing it unattended is not.
      assert CommitSubstance.substantive?(commit(files: ["mix.lock"]))
    end

    test "an AI-assisted commit is substantive" do
      # A person decided the project needed changing. `agentic_classification`
      # is the metric that speaks to how it was written; folding that in here
      # would answer a different question than this one asks.
      assert CommitSubstance.substantive?(
               commit(name: "Ada Lovelace", email: "ada@example.com", files: ["lib/thing.ex"])
             )
    end
  end

  describe "a commit that changed nothing" do
    # `Enum.all?([], ...)` is true, so an empty file list would be classified
    # by accident rather than by decision. It is non-substantive either way,
    # but for a stated reason.
    test "is not substantive" do
      refute CommitSubstance.substantive?(commit(files: []))
    end
  end

  describe "parsing git output" do
    @log "\x1eaaa\x1f2026-09-01T00:00:00Z\x1fAda\x1fada@example.com\n\nlib/a.ex\nREADME.md\n" <>
           "\x1ebbb\x1f2026-08-01T00:00:00Z\x1fdependabot[bot]\x1fdependabot@x\n\nmix.lock\n"

    test "reads commits newest first with their files" do
      [first, second] = CommitSubstance.parse_log(@log)

      assert first.sha == "aaa"
      assert first.author_name == "Ada"
      assert first.files == ["lib/a.ex", "README.md"]
      assert second.author_name == "dependabot[bot]"
      assert second.files == ["mix.lock"]
    end

    test "a path containing spaces or punctuation survives" do
      log = "\x1eccc\x1f2026-09-01T00:00:00Z\x1fAda\x1fada@x\n\nlib/some file, odd.ex\n"

      assert [%{files: ["lib/some file, odd.ex"]}] = CommitSubstance.parse_log(log)
    end

    test "git warnings on the same stream are not mistaken for paths" do
      log = "\x1eddd\x1f2026-09-01T00:00:00Z\x1fAda\x1fada@x\n\nwarning: something\nlib/a.ex\n"

      assert [%{files: ["lib/a.ex"]}] = CommitSubstance.parse_log(log)
    end

    test "empty output yields no commits rather than a malformed one" do
      assert CommitSubstance.parse_log("") == []
    end
  end
end
