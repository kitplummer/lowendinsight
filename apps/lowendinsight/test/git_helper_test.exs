defmodule GitHelperTest do
  use ExUnit.Case
  doctest GitHelper

  @moduledoc """
  This will test various functions in git_helper. However, since most of these functions
  are private, in order to test them you will need to make them public. I have added
  a tag :helper to all tests so that you may include or uninclude them accordingly.

  TODO: confirm that count can't be misconstrued and push the value so analysis can still be done
  """

  setup_all do
    correct_atr = "John R Doe <john@example.com> (1):\n messages for commits"
    incorrect_e = "John R Doe <asdfoi@2> (1):\n messages for commits"
    e_with_semi = "John R Doe <asdfjk@l;> (1):\n messages for commits"
    name_with_num = "098 567 45 <john@example.com> (10): \n messages for commits"
    empty_name = "<john@example.com> (1) \n messages for commits"
    name_angBr = "John < Doe <john@example.com> (1) \n messages for commmits"
    email_angBr = "John R Doe <john>example.com> (1) \n messages for commits"

    [
      correct_atr: correct_atr,
      incorrect_e: incorrect_e,
      e_with_semi: e_with_semi,
      name_with_num: name_with_num,
      empty_name: empty_name,
      name_angBr: name_angBr,
      email_angBr: email_angBr
    ]
  end

  setup do
    :ok
  end

  describe "parse_header/1" do
    @tag :helper
    test "correct implementation", %{correct_atr: correct_atr} do
      assert {"John R Doe ", "john@example.com", "1"} = GitHelper.parse_header(correct_atr)
    end

    @tag :helper
    test "incorrect email", %{incorrect_e: incorrect_e} do
      assert {"John R Doe ", "asdfoi@2", "1"} = GitHelper.parse_header(incorrect_e)
    end

    @tag :helper
    test "semicolon error", %{e_with_semi: e_with_semi} do
      assert {"Could not process", "Could not process", "0"} =
               GitHelper.parse_header(e_with_semi)
    end

    @tag :helper
    test "number error", %{name_with_num: name_with_num} do
      assert {"098 567 45 ", "john@example.com", "10"} = GitHelper.parse_header(name_with_num)
    end

    @tag :helper
    test "empty name error", %{empty_name: empty_name} do
      assert {"", "john@example.com", "1"} = GitHelper.parse_header(empty_name)
    end

    @tag :helper
    test "name with opening angle bracket", %{name_angBr: name_angBr} do
      assert {"John ", " Doe <john@example.com", "1"} = GitHelper.parse_header(name_angBr)
    end

    @tag :helper
    test "email with closing angle bracket", %{email_angBr: email_angBr} do
      assert {"John R Doe ", "john>example.com", "1"} = GitHelper.parse_header(email_angBr)
    end
  end

  describe "parse_diff/1" do
    test "parses diff with files, insertions, and deletions" do
      list = ["some output", " 3 files changed, 10 insertions(+), 5 deletions(-)"]
      assert {:ok, 3, 10, 5} = GitHelper.parse_diff(list)
    end

    test "parses diff with only files and insertions" do
      list = ["some output", " 2 files changed, 20 insertions(+)"]
      assert {:ok, 2, 20, 0} = GitHelper.parse_diff(list)
    end

    test "parses diff with only files" do
      list = ["some output", " 1 file changed"]
      assert {:ok, 1, 0, 0} = GitHelper.parse_diff(list)
    end

    test "parses diff with only files and deletions" do
      list = ["some output", " 4 files changed, 8 deletions(-)"]
      assert {:ok, 4, 8, 0} = GitHelper.parse_diff(list)
    end
  end

  describe "get_contributor_counts/1" do
    test "counts contributors from list" do
      list = ["Alice", "Bob", "Alice", "Carol", "Bob", "Alice"]
      {:ok, counts} = GitHelper.get_contributor_counts(list)

      assert Map.get(counts, "Alice") == 3
      assert Map.get(counts, "Bob") == 2
      assert Map.get(counts, "Carol") == 1
    end

    test "handles empty list" do
      {:ok, counts} = GitHelper.get_contributor_counts([])
      assert counts == %{}
    end

    test "skips empty strings" do
      list = ["Alice", "", "Bob", ""]
      {:ok, counts} = GitHelper.get_contributor_counts(list)

      assert Map.get(counts, "Alice") == 1
      assert Map.get(counts, "Bob") == 1
      refute Map.has_key?(counts, "")
    end
  end

  describe "get_filtered_contributor_count/2" do
    test "filters contributors below threshold" do
      map = %{"Alice" => 50, "Bob" => 30, "Carol" => 15, "Dave" => 5}
      total = 100

      {:ok, count, filtered} = GitHelper.get_filtered_contributor_count(map, total)

      # Threshold is 1/4 = 25% (100/4 contributors)
      # Alice (50%) and Bob (30%) should pass, Carol (15%) and Dave (5%) should not
      assert count == 2
      assert length(filtered) == 2
    end

    test "handles single contributor" do
      map = %{"Alice" => 100}
      total = 100

      {:ok, count, _filtered} = GitHelper.get_filtered_contributor_count(map, total)
      assert count == 1
    end

    test "handles empty map" do
      {:ok, count, filtered} = GitHelper.get_filtered_contributor_count(%{}, 0)
      assert count == 0
      assert filtered == []
    end
  end

  describe "split_commits_by_tag/1" do
    test "returns ok tuple for empty list" do
      {:ok, result} = GitHelper.split_commits_by_tag([])
      assert result == []
    end

    test "splits commits by tag" do
      # Data uses improper lists: ["tag" | timestamp] as created by git_module
      commits = [
        ["tag: v1.0" | 1000],
        ["" | 900],
        ["" | 800],
        ["tag: v0.9" | 700],
        ["" | 600]
      ]

      {:ok, result} = GitHelper.split_commits_by_tag(commits)
      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "get_total_tag_commit_time_diff/1" do
    test "handles empty list" do
      {:ok, result} = GitHelper.get_total_tag_commit_time_diff([])
      assert result == []
    end

    test "computes total time diff for tag groups" do
      # Data uses improper lists: ["tag" | timestamp] where tail is an integer
      groups = [
        [["tag: v1.0" | 1000], ["" | 900], ["" | 800]],
        [["tag: v0.9" | 500], ["" | 400]]
      ]

      {:ok, result} = GitHelper.get_total_tag_commit_time_diff(groups)
      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "get_avg_tag_commit_time_diff/1" do
    test "handles empty list" do
      {:ok, result} = GitHelper.get_avg_tag_commit_time_diff([])
      assert result == []
    end

    test "computes average time diff for tag groups" do
      # Data uses improper lists: ["tag" | timestamp] where tail is an integer
      groups = [
        [["tag: v1.0" | 1000], ["" | 900], ["" | 800]],
        [["tag: v0.9" | 500], ["" | 400]]
      ]

      {:ok, result} = GitHelper.get_avg_tag_commit_time_diff(groups)
      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "parse_shortlog/1" do
    test "parses valid shortlog" do
      log = """
      John Doe <john@example.com> (2):
        First commit
        Second commit

      Jane Smith <jane@example.com> (1):
        Another commit
      """

      result = GitHelper.parse_shortlog(log)
      assert is_list(result)
      assert length(result) == 2
    end

    test "returns contributor with error message for empty log" do
      result = GitHelper.parse_shortlog("")
      assert length(result) == 1
      assert hd(result).name == "Could not process"
    end

    test "aliases of one email become one contributor, counts summed" do
      # Deduplication is by email, case-insensitively, and the counts, merges
      # and commits of every alias are combined.
      log = """
      J. Doe <John@Example.com> (2):
        a
        b

      John Doe <john@example.com> (3):
        c
        d
        e

      Jane Smith <jane@example.com> (1):
        f
      """

      result = GitHelper.parse_shortlog(log)

      assert length(result) == 2

      doe = Enum.find(result, &(String.downcase(&1.email) == "john@example.com"))
      assert doe.count == 5, "alias counts were not summed"
      assert length(doe.commits) == 5, "alias commits were not combined"

      # The longest, most word-separated name wins, which is what name_sorter/1
      # scores and what the previous implementation chose.
      assert doe.name == "John Doe"
    end

    test "contributors come back in descending count order" do
      # `shortlog -n` emits them that way and callers rely on it:
      # get_top10_contributors_map/1 takes the first ten, so an unordered list
      # silently reports ten arbitrary contributors as the top ten.
      #
      # Forty, not three. Deduplication groups into a map, and a map with few
      # keys happens to iterate in insertion order -- a three-contributor
      # version of this test passed even with the sort removed, purely on how
      # those three email strings hashed. Above Elixir's flat-map threshold the
      # order is genuinely arbitrary: measured without the sort, forty
      # contributors came back as [32, 10, 14, 28, ...].
      n = 40

      log =
        Enum.map_join(n..1, "\n\n", fn i ->
          "Person #{i} <p#{i}@example.com> (#{i}):\n  commit"
        end)

      counts = GitHelper.parse_shortlog(log) |> Enum.map(& &1.count)

      assert counts == Enum.to_list(n..1),
             "order is not by descending count: #{inspect(Enum.take(counts, 6))}..."
    end

    test "deduplication is linear, not quadratic, in contributors" do
      # The defect this guards. Deduplication was two full list traversals per
      # unique contributor, recursing on the remainder -- O(n^2) -- and every
      # comparison called String.downcase on both sides.
      #
      # Measured before the fix: 3,366 ms for React's 2,042 contributors
      # against 149 ms for the `git shortlog` that produced the input, and
      # DefinitelyTyped's 19,983 did not finish in minutes. A full analysis of
      # DefinitelyTyped took 37.5 minutes; after the fix, 15.8 seconds.
      #
      # Timing is the only way to catch a complexity regression, so this
      # asserts a ratio. Two things make the ratio trustworthy, both learned
      # from this test failing on CI at 3.3x with 3,579us against 11,734us --
      # at single-digit milliseconds a garbage collection is the whole signal:
      #
      #   * **sizes large enough that work dominates noise.** 500 and 1,000
      #     contributors were too small. 2,000 and 4,000 take tens of
      #     milliseconds here and more on a loaded runner.
      #   * **the minimum of several runs**, which is the sample least
      #     disturbed by a pause. The mean would carry the outlier that failed
      #     CI.
      #
      # Locally this gives 1.8x. With the quadratic restored it is ~4x and the
      # absolute times diverge enormously, so the threshold has room.
      build = fn n ->
        Enum.map_join(1..n, "\n\n", fn i ->
          "Person #{i} <p#{i}@example.com> (1):\n  commit #{i}"
        end)
      end

      small = build.(2_000)
      large = build.(4_000)

      # Warm the code path so the first measurement is not paying for it.
      GitHelper.parse_shortlog(build.(50))

      best = fn input ->
        Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> GitHelper.parse_shortlog(input) end), 0))
      end

      t_small = best.(small)
      t_large = best.(large)

      assert length(GitHelper.parse_shortlog(small)) == 2_000
      assert length(GitHelper.parse_shortlog(large)) == 4_000

      # Below a millisecond any ratio is noise, so say so rather than assert
      # something meaningless. This should not trigger at these sizes.
      if t_small < 1_000 do
        IO.puts("  (skipped: #{t_small}us is too fast to compare meaningfully)")
      else
        ratio = t_large / t_small

        assert ratio < 3.0,
               "doubling contributors multiplied the time by #{Float.round(ratio, 1)}x " <>
                 "(#{t_small}us -> #{t_large}us), which is superlinear"
      end
    end
  end
end
