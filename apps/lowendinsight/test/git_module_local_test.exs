# Tests for GitModule that use the local repository (no network needed)

defmodule GitModuleLocalTest do
  use ExUnit.Case, async: false

  setup_all do
    {:ok, repo} = GitModule.get_repo(".")
    [repo: repo]
  end

  test "get_repo returns repo for current directory" do
    {:ok, repo} = GitModule.get_repo(".")
    assert repo.path == "."
  end

  test "get_repo returns error for non-git directory" do
    {:error, _msg} = GitModule.get_repo(System.tmp_dir!())
  end

  test "get_hash returns a valid commit hash", %{repo: repo} do
    {:ok, hash} = GitModule.get_hash(repo)
    assert is_binary(hash)
    assert String.length(hash) == 40
    assert String.match?(hash, ~r/^[0-9a-f]+$/)
  end

  test "get_last_commit_date returns an ISO8601 date", %{repo: repo} do
    {:ok, date} = GitModule.get_last_commit_date(repo)
    assert is_binary(date)
    assert String.contains?(date, "T")
  end

  test "get_default_branch returns a branch or undeterminable", %{repo: repo} do
    {:ok, branch} = GitModule.get_default_branch(repo)
    assert is_binary(branch)
  end

  test "get_total_commit_count returns a count", %{repo: repo} do
    {:ok, result} = GitModule.get_total_commit_count(repo)
    assert is_integer(result) or is_binary(result)
  end

  test "get_contributor_count returns positive count", %{repo: repo} do
    {:ok, count} = GitModule.get_contributor_count(repo)
    assert is_integer(count)
    assert count > 0
  end

  test "get_commit_dates returns list of timestamps", %{repo: repo} do
    {:ok, dates} = GitModule.get_commit_dates(repo)
    assert is_list(dates)
    assert length(dates) > 0
    assert Enum.all?(dates, &is_integer/1)
  end

  test "get_contributors returns list of contributors", %{repo: repo} do
    {:ok, contributors} = GitModule.get_contributors(repo)
    assert is_list(contributors)
    assert length(contributors) > 0
  end

  test "get_contributor_distribution returns distribution map", %{repo: repo} do
    {:ok, distribution, total} = GitModule.get_contributor_distribution(repo)
    assert is_map(distribution)
    assert is_integer(total)
    assert total > 0
  end

  test "get_functional_contributors returns count and names", %{repo: repo} do
    {:ok, count, names} = GitModule.get_functional_contributors(repo)
    assert is_integer(count)
    assert count > 0
    assert is_list(names)
  end

  test "get_contributions_map returns list of contribution maps", %{repo: repo} do
    {:ok, maps} = GitModule.get_contributions_map(repo)
    assert is_list(maps)
    assert length(maps) > 0
    first = hd(maps)
    assert Map.has_key?(first, :name)
    assert Map.has_key?(first, :contributions)
  end

  test "get_clean_contributions_map returns clean map", %{repo: repo} do
    {:ok, maps} = GitModule.get_clean_contributions_map(repo)
    assert is_list(maps)
    first = hd(maps)
    assert Map.has_key?(first, :name)
    assert Map.has_key?(first, :contributions)
    assert Map.has_key?(first, :merges)
    assert Map.has_key?(first, :email)
  end

  test "get_top10_contributors_map returns at most 10 entries", %{repo: repo} do
    {:ok, maps} = GitModule.get_top10_contributors_map(repo)
    assert is_list(maps)
    assert length(maps) <= 10
    assert length(maps) > 0
  end

  test "get_last_n_commits returns commit hashes", %{repo: repo} do
    {:ok, commits} = GitModule.get_last_n_commits(repo, 5)
    assert is_list(commits)
    assert length(commits) <= 5
  end

  test "get_diff_2_commits returns diff lines", %{repo: repo} do
    {:ok, commits} = GitModule.get_last_n_commits(repo, 2)

    if length(commits) >= 2 do
      {:ok, diffs} = GitModule.get_diff_2_commits(repo, commits)
      assert is_list(diffs)
    end
  end

  test "get_total_lines returns line and file counts", %{repo: repo} do
    {:ok, lines, files} = GitModule.get_total_lines(repo)
    assert is_integer(lines)
    assert is_integer(files)
    assert lines > 0
    assert files > 0
  end

  test "get_recent_changes returns percentage values", %{repo: repo} do
    {:ok, line_pct, file_pct} = GitModule.get_recent_changes(repo)
    assert is_number(line_pct)
    assert is_number(file_pct)
    assert line_pct >= 0
    assert file_pct >= 0
  end

  test "get_last_2_delta returns delta values", %{repo: repo} do
    {:ok, files_changed, insertions, deletions} = GitModule.get_last_2_delta(repo)
    assert is_number(files_changed)
    assert is_number(insertions)
    assert is_number(deletions)
  end

  test "get_repo_size returns a size string", %{repo: repo} do
    {:ok, size} = GitModule.get_repo_size(repo)
    assert is_binary(size)
  end

  test "get_last_contribution_date_by_contributor returns a date", %{repo: repo} do
    {:ok, contributors} = GitModule.get_contributors(repo)
    first_contributor = hd(contributors)

    date = GitModule.get_last_contribution_date_by_contributor(repo, first_contributor.name)
    assert is_binary(date) or is_nil(date)
  end

  test "clone_repo returns error for invalid URL" do
    {:ok, tmp_path} = Temp.path("lei-test")
    File.mkdir_p!(tmp_path)

    result =
      GitModule.clone_repo(
        "https://github.com/nonexistent-user-12345/nonexistent-repo-67890",
        tmp_path
      )

    assert {:error, _} = result

    File.rm_rf!(tmp_path)
  end

  test "get_tag_and_commit_dates returns tagged commit data", %{repo: repo} do
    result = GitModule.get_tag_and_commit_dates(repo)
    # Should return {:ok, list} with commit date information
    assert {:ok, _data} = result
  end

  test "get_clean_contributions_map handles various contributor names", %{repo: repo} do
    {:ok, maps} = GitModule.get_clean_contributions_map(repo)
    assert is_list(maps)
    assert length(maps) > 0

    # Verify all names are valid strings (raw_binary_to_string was applied)
    Enum.each(maps, fn entry ->
      assert is_binary(entry.name)
      assert String.valid?(entry.name)
    end)
  end

  describe "with tagged repo" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "lei_git_tag_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      System.cmd("git", ["init"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "# Test\n")
      System.cmd("git", ["add", "."], cd: tmp_dir)

      git_env = [
        {"GIT_AUTHOR_NAME", "Test"},
        {"GIT_AUTHOR_EMAIL", "test@test.com"},
        {"GIT_COMMITTER_NAME", "Test"},
        {"GIT_COMMITTER_EMAIL", "test@test.com"}
      ]

      System.cmd("git", ["commit", "-m", "initial"], cd: tmp_dir, env: git_env)

      System.cmd("git", ["tag", "v1.0.0"], cd: tmp_dir)

      File.write!(Path.join(tmp_dir, "README.md"), "# Test v2\n")
      System.cmd("git", ["add", "."], cd: tmp_dir)

      System.cmd("git", ["commit", "-m", "second commit"], cd: tmp_dir, env: git_env)

      System.cmd("git", ["tag", "v2.0.0"], cd: tmp_dir)

      {:ok, tagged_repo} = GitModule.get_repo(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      [tagged_repo: tagged_repo, tagged_dir: tmp_dir]
    end

    test "get_tag_and_commit_dates returns data for tagged commits", %{tagged_repo: repo} do
      result = GitModule.get_tag_and_commit_dates(repo)
      assert {:ok, data} = result
      assert is_list(data)
    end

    test "get_commit_dates returns timestamps", %{tagged_repo: repo} do
      {:ok, dates} = GitModule.get_commit_dates(repo)
      assert length(dates) == 2
    end

    test "get_last_n_commits returns correct count", %{tagged_repo: repo} do
      {:ok, commits} = GitModule.get_last_n_commits(repo, 5)
      assert length(commits) == 2
    end

    test "get_recent_changes works with small repo", %{tagged_repo: repo} do
      {:ok, line_pct, file_pct} = GitModule.get_recent_changes(repo)
      assert is_number(line_pct)
      assert is_number(file_pct)
    end

    test "get_default_branch returns undeterminable for repo without remote", %{tagged_repo: repo} do
      {:ok, branch} = GitModule.get_default_branch(repo)
      assert branch =~ "undeterminable"
    end

    test "get_total_commit_count returns undeterminable for repo without remote", %{
      tagged_repo: repo
    } do
      {:ok, result} = GitModule.get_total_commit_count(repo)
      assert is_binary(result)
      assert result =~ "undeterminable"
    end

    test "get_contributor_count returns count", %{tagged_repo: repo} do
      {:ok, count} = GitModule.get_contributor_count(repo)
      assert count == 1
    end

    test "get_contributors returns contributor list", %{tagged_repo: repo} do
      {:ok, contributors} = GitModule.get_contributors(repo)
      assert length(contributors) == 1
      assert hd(contributors).name == "Test"
    end

    test "get_functional_contributors works with small repo", %{tagged_repo: repo} do
      {:ok, count, names} = GitModule.get_functional_contributors(repo)
      assert count >= 1
      assert is_list(names)
    end

    test "get_repo_size works", %{tagged_repo: repo} do
      {:ok, size} = GitModule.get_repo_size(repo)
      assert is_binary(size)
    end

    test "get_hash returns valid hash", %{tagged_repo: repo} do
      {:ok, hash} = GitModule.get_hash(repo)
      assert String.length(hash) == 40
    end
  end

  describe "a contributor name is data, not a pattern" do
    # `--author` is a regex. apache/arrow has a commit authored by
    # `<ESC>[5~David Li` -- a real name, with a terminal control sequence
    # someone's git config picked up at some point. The unterminated `[` is an
    # invalid character class:
    #
    #     fatal: header, '?[5~David Li': Unmatched [, [^, [:, [., or [=
    #
    # git exits 128, `Lei.Git.run!/3` raises, and the entire repository is lost.
    # pyarrow is in the top twenty PyPI packages and that is what happened to it
    # during the 2026-10-03 study run.
    #
    # The name here has no ESC, and that is deliberate. A first version of this
    # test used the byte-for-byte name from the failure and asserted a date; it
    # failed, because **git strips the ESC when storing the author** --
    # `%an` comes back as `[5~David Li`. Searching for the ESC form then matches
    # nothing, so the test was asserting a condition `git commit` cannot create.
    #
    # The `[` is the bug and git stores it faithfully, so this is the
    # reproducible form:
    #
    #     --author=[5~David Li        exit 128, Unmatched [
    #     -F --author=[5~David Li     exit 0, returns the date
    @awkward "[5~David Li"

    defp repo_authored_by(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "author-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      env = [
        {"GIT_AUTHOR_NAME", name},
        {"GIT_AUTHOR_EMAIL", "awkward@example.com"},
        {"GIT_COMMITTER_NAME", name},
        {"GIT_COMMITTER_EMAIL", "awkward@example.com"}
      ]

      for args <- [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "awkward@example.com"],
            ["config", "user.name", name]
          ] do
        {_, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
      end

      File.write!(Path.join(dir, "f"), "x\n")
      {_, 0} = System.cmd("git", ["add", "f"], cd: dir, env: env, stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["commit", "-q", "-m", "one"],
          cd: dir,
          env: env,
          stderr_to_stdout: true
        )

      {:ok, repo} = GitModule.get_repo(dir)
      repo
    end

    test "an unterminated bracket in a name does not lose the repository" do
      repo = repo_authored_by(@awkward)

      date = GitModule.get_last_contribution_date_by_contributor(repo, @awkward)

      assert is_binary(date), "expected a date, got #{inspect(date)}"
      assert String.contains?(date, "T"), "expected an ISO8601 date, got #{inspect(date)}"
    end

    test "an ordinary name still matches" do
      # The fix must not make the lookup match nothing: a literal search that
      # finds no commits would return an empty string for every contributor,
      # and every repository would look like it had no recent contribution.
      repo = repo_authored_by("Ordinary Person")

      date = GitModule.get_last_contribution_date_by_contributor(repo, "Ordinary Person")

      assert is_binary(date)
      assert String.contains?(date, "T")
    end

    test "a name that is not a contributor returns nothing, rather than matching loosely" do
      # With `--author` as a regex, "Ordinary" would match "Ordinary Person" as a
      # substring; so would a crafted pattern like `.*`. A literal search still
      # matches on substring -- git's -F means fixed string, not whole field --
      # so what this pins is that an absent contributor finds no commit.
      repo = repo_authored_by("Ordinary Person")

      assert GitModule.get_last_contribution_date_by_contributor(repo, "Nobody At All") == ""
    end
  end
end
