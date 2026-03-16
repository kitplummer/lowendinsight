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
  end
end
