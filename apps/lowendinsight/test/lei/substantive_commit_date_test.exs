defmodule Lei.SubstantiveCommitDateTest do
  @moduledoc """
  Finding the last commit that meant something, against real git (#244).

  `Lei.CommitSubstance` is tested on parsed structures; this drives the whole
  path -- a real repository, a real `git log --name-only`, real author
  metadata -- because the failure this metric exists to prevent is a
  repository that looks maintained, and only git can produce the log that
  makes it look that way.

  Each repository below is built commit by commit with dates set explicitly,
  so "the most recent human commit that touched code" is a known answer rather
  than whatever the fixture happened to contain.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_git

  defp git!(dir, args, env \\ []) do
    {_, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    :ok
  end

  # The OS pid is in the name, not only a unique integer.
  #
  # `System.unique_integer/1` is unique *within a VM* and starts low in each
  # one, so two `mix test` processes can produce the same name -- and did.
  # Both then write commits into one repository, and when the first one's
  # `on_exit` removes it while the second is still committing, `File.rm_rf!`
  # raises `:eexist`, which is what Erlang returns for a non-empty directory.
  #
  # Reproduced rather than inferred: `File.rm_rf!` on a directory with a
  # concurrent writer raises exactly `{:raised, :eexist}`, which is the error
  # CI reported on 2026-10-02 for `/tmp/subst-5698`.
  #
  # So the name is made impossible to collide instead of the removal being made
  # tolerant. A tolerant `rm_rf` would hide a genuine cleanup failure, and the
  # test would keep sharing a repository with another VM -- which is a wrong
  # answer, not only a messy one. Eight other test files build temp names the
  # same way; this is the one that has bitten.
  defp repo_with(commits) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "subst-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "setup@example.com"])
    git!(dir, ["config", "user.name", "Setup"])

    for {days_ago, name, email, files} <- commits do
      for f <- files do
        path = Path.join(dir, f)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "content #{System.unique_integer([:positive])}\n")
      end

      stamp =
        DateTime.utc_now()
        |> DateTime.add(-days_ago * 86_400, :second)
        |> DateTime.to_iso8601()

      git!(dir, ["add", "-A"])

      git!(
        dir,
        ["commit", "-q", "-m", "#{name}: #{Enum.join(files, ", ")}"],
        [
          {"GIT_AUTHOR_NAME", name},
          {"GIT_AUTHOR_EMAIL", email},
          {"GIT_COMMITTER_NAME", name},
          {"GIT_COMMITTER_EMAIL", email},
          {"GIT_AUTHOR_DATE", stamp},
          {"GIT_COMMITTER_DATE", stamp}
        ]
      )
    end

    Lei.Git.new(dir)
  end

  defp days_since(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.diff(DateTime.utc_now(), dt) |> div(86_400)
  end

  @human {"Ada Lovelace", "ada@example.com"}
  @bot {"dependabot[bot]", "49699333+dependabot[bot]@users.noreply.github.com"}

  test "a repository kept warm by a bot reports its real last human commit" do
    {hn, he} = @human
    {bn, be} = @bot

    repo =
      repo_with([
        {400, hn, he, ["lib/core.ex"]},
        {200, bn, be, ["mix.lock"]},
        {30, bn, be, ["mix.lock"]},
        {2, bn, be, ["mix.lock"]}
      ])

    {:ok, plain} = GitModule.get_last_commit_date(repo)
    {:ok, substantive, :found} = GitModule.get_last_substantive_commit_date(repo)

    # The metric as it was: two days old, and reads as a thriving project.
    assert days_since(plain) <= 3

    # The metric as it should be: nobody has touched this in over a year.
    assert days_since(substantive) >= 399
  end

  test "a README fix does not count as maintenance" do
    {hn, he} = @human

    repo =
      repo_with([
        {300, hn, he, ["lib/core.ex"]},
        {5, hn, he, ["README.md"]}
      ])

    {:ok, plain} = GitModule.get_last_commit_date(repo)
    {:ok, substantive, :found} = GitModule.get_last_substantive_commit_date(repo)

    assert days_since(plain) <= 6
    assert days_since(substantive) >= 299
  end

  test "an actively developed repository is unaffected" do
    {hn, he} = @human

    repo =
      repo_with([
        {40, hn, he, ["lib/core.ex"]},
        {3, hn, he, ["lib/feature.ex"]}
      ])

    {:ok, plain} = GitModule.get_last_commit_date(repo)
    {:ok, substantive, :found} = GitModule.get_last_substantive_commit_date(repo)

    assert days_since(plain) == days_since(substantive)
  end

  test "the working directory cannot collide with another test process" do
    # The flake this guards: two `mix test` VMs producing the same temp name,
    # writing commits into one repository, and one removing it while the other
    # writes. System.unique_integer/1 is per-VM and starts low, so the OS pid is
    # what makes the name unique across processes.
    {hn, he} = @human
    repo = repo_with([{1, hn, he, ["lib/core.ex"]}])

    assert repo.path =~ System.pid(),
           "the temp directory name does not include the OS pid, so a second VM can pick it: #{repo.path}"
  end

  test "a repository with nothing substantive in the window says so" do
    {bn, be} = @bot

    repo =
      repo_with([
        {90, bn, be, ["mix.lock"]},
        {60, bn, be, ["mix.lock"]},
        {10, bn, be, ["mix.lock"]}
      ])

    {:ok, date, :window_exhausted} = GitModule.get_last_substantive_commit_date(repo)

    # The oldest commit examined. The true answer is older, so the age derived
    # from this understates staleness rather than inventing a figure.
    assert days_since(date) >= 89
  end

  test "the window bounds the walk" do
    {hn, he} = @human
    {bn, be} = @bot

    repo =
      repo_with(
        [{500, hn, he, ["lib/core.ex"]}] ++
          for(i <- 1..12, do: {i * 10, bn, be, ["mix.lock"]})
      )

    # Searching only the 5 most recent cannot reach the human commit.
    assert {:ok, _, :window_exhausted} = GitModule.get_last_substantive_commit_date(repo, 5)

    # Searching far enough does.
    assert {:ok, found, :found} = GitModule.get_last_substantive_commit_date(repo, 100)
    assert days_since(found) >= 499
  end
end
