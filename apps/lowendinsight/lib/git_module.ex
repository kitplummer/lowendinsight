# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule GitModule do
  @moduledoc """
  Collections of functions for interacting with the `git` command to perform queries.
  """
  @behaviour GitModule.Behaviour

  @doc """
  clone_repo/2: clones the repo
  """
  @spec clone_repo(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def clone_repo(url, tmp_path) do
    {:ok, slug} = url |> Helpers.get_slug()
    {:ok, _, repo_name} = Helpers.split_slug(slug)

    ## repo_name needs to go to a tmp path struct
    tmp_repo_path = Path.join(tmp_path, repo_name)

    with {:ok, repo} <- Lei.Git.clone(url, tmp_repo_path),
         {:ok, _} <- Lei.Git.run(repo, ["log", "-1"]) do
      {:ok, repo}
    else
      _error -> {:error, "Repository not found"}
    end
  end

  @doc """
  get_repo/1: gets a repo by path, returns Repository struct
  """
  @spec get_repo(String.t()) :: {:ok, Lei.Git.Repository.t()} | {:error, String.t()}
  def get_repo(path) do
    with repo <- Lei.Git.new(path),
         {:ok, _} <- Lei.Git.run(repo, ["status"]) do
      {:ok, repo}
    else
      # Lei.Git.run/3 reports {:error, status, output}; the status is what
      # there is to say, and the output is git's own text, which is not ours
      # to pass on (#149).
      {:error, status, _out} -> {:error, "not a readable git repository (git exited #{status})"}
    end
  end

  @doc """
  get_last_substantive_commit_date/2: the date of the most recent commit that
  says something about the project being maintained (#244).

  Bots and documentation-only commits reset the plain commit clock without
  representing any attention, so currency measured from them can report a
  healthy project that nobody has touched in a year. `Lei.CommitSubstance`
  holds the definition; this walks the log newest-first and stops at the first
  commit that meets it.

  Returns `{:ok, date, :found}`, or `{:ok, date, :window_exhausted}` when none
  of the `limit` most recent commits was substantive. In that case `date` is
  the oldest commit examined: the true answer is older still, so the age
  derived from it is a lower bound. Understating staleness is the safe
  direction to be wrong in, and it beats inventing a figure we cannot see.

  `{:error, :no_commits}` when the log yields nothing parseable.
  """
  @spec get_last_substantive_commit_date(Lei.Git.Repository.t(), pos_integer) ::
          {:ok, String.t(), :found | :window_exhausted} | {:error, :no_commits}
  def get_last_substantive_commit_date(repo, limit \\ 150) do
    commits =
      repo
      |> Lei.Git.run!([
        "log",
        "--no-merges",
        "-n",
        Integer.to_string(limit),
        "--name-only",
        "--pretty=format:%x1e%H%x1f%cI%x1f%an%x1f%ae"
      ])
      |> Lei.CommitSubstance.parse_log()

    case Enum.find(commits, &Lei.CommitSubstance.substantive?/1) do
      %{date: date} ->
        {:ok, date, :found}

      nil ->
        case List.last(commits) do
          %{date: oldest} -> {:ok, oldest, :window_exhausted}
          nil -> {:error, :no_commits}
        end
    end
  end

  @doc """
  get_contributors_count/1: returns the number of contributors for
  a given Git repo
  """
  @spec get_contributor_count(Lei.Git.Repository.t()) :: {:ok, non_neg_integer}
  def get_contributor_count(repo) do
    count =
      Lei.Git.run!(repo, ["shortlog", "-s", "-n", "HEAD", "--"])
      |> String.trim()
      |> String.split(~r{\s\s+})
      |> Enum.count()

    {:ok, count}
  end

  @doc """
  get_last_commit_date/1: returns the date of the last commit
  """
  @spec get_last_commit_date(Lei.Git.Repository.t()) :: {:ok, String.t()}
  def get_last_commit_date(repo) do
    date = List.last(git_log_split(repo, ["-1", "--pretty=format:%cI"]))
    {:ok, date}
  end

  @spec delete_repo(
          atom
          | %{
              :path =>
                binary
                | maybe_improper_list(
                    binary | maybe_improper_list(any, binary | []) | char,
                    binary | []
                  ),
              optional(any) => any
            }
        ) :: [binary]
  def delete_repo(repo) do
    File.rm_rf!(repo.path)
  end

  @doc """
  get_current_hash/1: returns the hash of the repo's HEAD
  """
  @spec get_hash(Lei.Git.Repository.t()) :: {:ok, String.t()}
  def get_hash(repo) do
    hash = Lei.Git.run!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, hash}
  end

  @doc """
  get_default_branch/1: returns the default branch of the remote repo
  """
  @spec get_default_branch(Lei.Git.Repository.t()) :: {:ok, String.t()}
  def get_default_branch(repo) do
    try do
      default_branch =
        Lei.Git.run!(repo, ["symbolic-ref", "refs/remotes/origin/HEAD"]) |> String.trim()

      {:ok, default_branch}
    rescue
      _e in Lei.Git.Error -> {:ok, "undeterminable, not at HEAD"}
    end
  end

  @doc """
  get_total_commit_count/2: returns the count of commits for a provided branch
  """
  def get_total_commit_count(repo) do
    try do
      count =
        Lei.Git.run!(repo, ["rev-list", "--count", "refs/remotes/origin/HEAD"])
        |> String.trim_trailing()
        |> String.to_integer()

      {:ok, count}
    rescue
      _e in Lei.Git.Error -> {:ok, "undeterminable, branch issue"}
    end
  end

  @doc """
  get_commit_dates/1: returns a list of unix timestamps representing commit times
  """
  @spec get_commit_dates(Lei.Git.Repository.t()) :: {:ok, [non_neg_integer]}
  def get_commit_dates(repo) do
    dates = git_log_split(repo, ["--pretty=format:%ct"])

    dates_int = Enum.map(dates, fn x -> String.to_integer(x, 10) end)
    {:ok, dates_int}
  end

  @spec get_tag_and_commit_dates(Lei.Git.Repository.t()) :: {:ok, [[...]]}
  @doc """
  get_tag_and_commit_dates/1: returns a list of lists of unix timestamps
  representing commit times with each lsit belonging to a different tag
  """
  def get_tag_and_commit_dates(repo) do
    tag_and_date =
      git_log_split(repo, ["--pretty=format:%d$%ct"])
      |> Enum.map(fn element -> String.split(element, "$") end)
      |> Enum.map(fn [head | tail] ->
        if head == "" do
          ["" | String.to_integer(Enum.at(tail, 0), 10)]
        else
          [
            String.trim(String.trim(String.trim(head), "("), ")")
            | String.to_integer(Enum.at(tail, 0), 10)
          ]
        end
      end)

    GitHelper.split_commits_by_tag(tag_and_date)
  end

  @doc """
  get_last_n_commits/1: returns a list of the short hashes of the last n commits
  """
  @spec get_last_n_commits(Lei.Git.Repository.t(), non_neg_integer) :: {:ok, [any]}
  def get_last_n_commits(repo, n) do
    output = git_log_split(repo, ["--pretty=format:%h", "--no-merges", "-#{n}"])
    {:ok, output}
  end

  @doc """
  get_last_n_commits/2: returns a list of lines generated from the diff of two commits
  """
  @spec get_diff_2_commits(Lei.Git.Repository.t(), [any]) :: {:ok, [String.t()]} | []
  def get_diff_2_commits(repo, [commit1 | [commit2 | []]]) do
    with {:ok, diff} <- Lei.Git.run(repo, ["diff", "--stat", commit1, commit2]) do
      {:ok, String.split(String.trim_trailing(diff, "\n"), "\n")}
    else
      _ -> []
    end
  end

  @doc """
  get_total_lines/1: returns the total lines and files contained in a repo as of the latest commit
  """
  @spec get_total_lines(Lei.Git.Repository.t()) :: {:ok, non_neg_integer, non_neg_integer}
  def get_total_lines(repo) do
    {:ok, hash} = Lei.Git.run(repo, ["hash-object", "-t", "tree", "/dev/null"])

    {:ok, diff} =
      Lei.Git.run(repo, ["diff", "--shortstat", String.replace_suffix(hash, "\n", "")])

    [files_changed | [lines_changed | _tail]] = String.split(diff, ", ")
    [file_num | _tail] = String.split(String.trim(files_changed), " ")
    [line_num | _tail] = String.split(lines_changed, " ")
    {:ok, String.to_integer(line_num), String.to_integer(file_num)}
  end

  @spec get_recent_changes(Lei.Git.Repository.t()) :: {:ok, number, number}
  @doc """
  get_recent_changes/1: returns the percentage of changed lines in the last commit by the total lines in the repo
  """
  def get_recent_changes(repo) do
    with {:ok, total_lines, total_files_changed} <- get_total_lines(repo),
         {:ok, file_num, insertions, deletions} = get_last_2_delta(repo) do
      if total_lines == 0 do
        {:ok, 0, 0}
      else
        {:ok, Float.round((insertions + deletions) / total_lines, 5),
         Float.round(file_num / total_files_changed, 5)}
      end
    end
  end

  @doc """
  get_last_2_delta/1: returns the lines changed, files changed, additions and deletions in the last commit
  """
  @spec get_last_2_delta(Lei.Git.Repository.t()) ::
          {:ok, non_neg_integer, non_neg_integer, non_neg_integer}
  def get_last_2_delta(repo) do
    {:ok, commits} = get_last_n_commits(repo, 2)

    cond do
      length(commits) >= 2 ->
        {:ok, diffs} = get_diff_2_commits(repo, commits)

        if diffs == [""] do
          {:ok, 0, 0, 0}
        else
          GitHelper.parse_diff(diffs)
        end

      length(commits) < 2 ->
        {:ok, 0, 0, 0}
    end
  end

  @spec get_contributors(Lei.Git.Repository.t()) :: {:ok, [Contributor.t()]}
  def get_contributors(repo) do
    list =
      Lei.Git.run!(repo, ["shortlog", "-n", "-e", "HEAD", "--"])
      |> GitHelper.repair_utf8()
      |> GitHelper.parse_shortlog()

    {:ok, list}
  end

  @spec get_contributor_distribution(Lei.Git.Repository.t()) :: {:ok, map, non_neg_integer}
  def get_contributor_distribution(repo) do
    {:ok, contributors} = get_contributors(repo)
    # Helper function
    get_counts = fn contrib -> contrib.count end
    get_signoff = fn contrib -> contrib.name <> " <" <> contrib.email <> ">" end
    # Calcualte for eache
    counts_kwlist = for a <- contributors, do: {get_signoff.(a), get_counts.(a)}
    counts = Enum.into(counts_kwlist, %{})
    # Calculate for all
    total_contributions = Enum.sum(for a <- contributors, do: get_counts.(a))
    {:ok, counts, total_contributions}
  end

  @spec get_functional_contributors(Lei.Git.Repository.t()) :: {:ok, non_neg_integer, [any]}
  def get_functional_contributors(repo) do
    {:ok, counts, total} = get_contributor_distribution(repo)
    {:ok, length, filtered_list} = GitHelper.get_filtered_contributor_count(counts, total)
    {:ok, length, Enum.map(filtered_list, fn {name, _value} -> name end)}
  end

  @doc """
  get_contributions_map/1: returns a map of contributions per git user
  note: this map is unfiltered, dupes aren't identified
  """
  @spec get_contributions_map(Lei.Git.Repository.t()) ::
          {:ok, [%{contributions: non_neg_integer, name: String.t()}]}
  def get_contributions_map(repo) do
    {:ok, contrib} = get_contributors(repo)

    map =
      Enum.map(
        contrib,
        fn x ->
          %{
            :name => x.name,
            :contributions => x.count,
            :last_contribution_date => get_last_contribution_date_by_contributor(repo, x.name)
          }
        end
      )

    {:ok, map}
  end

  @spec get_clean_contributions_map(Lei.Git.Repository.t()) :: {:ok, list}
  def get_clean_contributions_map(repo) do
    map =
      Lei.Git.run!(repo, ["shortlog", "-n", "-e", "HEAD", "--"])
      |> GitHelper.parse_shortlog()
      |> Enum.map(fn contributor ->
        name =
          cond do
            contributor.name == nil -> "UNKNOWN"
            contributor.name == "" -> "UNKNOWN"
            contributor.name != "" -> raw_binary_to_string(contributor.name)
          end

        %{
          name: raw_binary_to_string(name),
          contributions: contributor.count,
          merges: contributor.merges,
          email: contributor.email,
          last_contribution_date: contributor.last_contribution_date
        }
      end)

    {:ok, map}
  end

  @doc """
      get_top10_contributors_map/1: Gets the top 10 contributors and returns it
      as a list of contributors with the commits list stripped from the map.
  """
  @spec get_top10_contributors_map(Lei.Git.Repository.t()) :: {:ok, [any]}
  def get_top10_contributors_map(repo) do
    {:ok, contrib} = get_contributors(repo)

    map10 =
      Enum.sort_by(contrib, & &1.count, &>=/2)
      |> Stream.take(10)
      |> Stream.map(fn x ->
        Map.put(x, :contributions, x.count)
      end)
      |> Stream.map(fn x ->
        Map.put(
          x,
          :last_contribution_date,
          get_last_contribution_date_by_contributor(repo, x.name)
        )
      end)
      |> Stream.map(fn x ->
        Map.drop(x, [:commits, :count, :__struct__])
      end)
      |> Enum.to_list()

    {:ok, map10}
  end

  @doc """
  get_last_contribution_date_by_contributor/1: returns the date of the last author or commit whichever
  is more recent.
  """
  def get_last_contribution_date_by_contributor(repo, contributor) do
    ## Using author here, as even if there is a different committer, the author is the contributor
    author_date =
      List.last(git_log_split(repo, ["--author=#{contributor}", "-1", "--pretty=format:%cI"]))

    author_date
  end

  @doc """
  get_commits_with_trailers/1: returns a list of maps with author_email and body
  for all commits. Used for detecting AI co-author trailers.
  """
  @spec get_commits_with_trailers(Lei.Git.Repository.t()) :: {:ok, [map()]}
  def get_commits_with_trailers(repo) do
    separator = "---LEI_SEPARATOR---"

    # Only commits whose message mentions a co-author can yield one: every
    # pattern Lei.AgenticDetector matches is a "Co-Authored-By:" line. Asking
    # git for just those commits gives identical detection, where reading every
    # commit body held the whole history in memory -- part of what OOM-killed
    # production analysing large repositories (#158).
    raw =
      Lei.Git.run!(repo, [
        "log",
        "-i",
        "-F",
        "--grep=Co-Authored-By:",
        "--pretty=format:%ae\t%B#{separator}"
      ])
      |> String.split(separator)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    commits =
      Enum.map(raw, fn entry ->
        case String.split(entry, "\t", parts: 2) do
          [email, body] -> %{author_email: email, body: body}
          [email] -> %{author_email: email, body: ""}
          _ -> nil
        end
      end)
      |> Enum.filter(&(not is_nil(&1)))

    {:ok, commits}
  end

  @spec get_repo_size(Lei.Git.Repository.t()) :: {:ok, String.t()}
  def get_repo_size(repo) do
    space =
      elem(System.cmd("git", ["count-objects"], cd: repo.path), 0)
      |> String.trim()
      |> String.split(",")
      |> Enum.at(1)
      |> String.trim()
      |> String.split(" ")
      |> List.first()

    {:ok, space}
  end

  @spec raw_binary_to_string(binary) :: String.t()
  defp raw_binary_to_string(raw) do
    String.codepoints(raw)
    |> Enum.reduce(fn w, result ->
      cond do
        String.valid?(w) ->
          result <> w

        true ->
          <<parsed::8>> = w
          result <> <<parsed::utf8>>
      end
    end)
  end

  # Was a replacement for Git.log! that stripped "warning:" lines, because
  # git_cli merged stderr into stdout and git's commentary arrived mixed into
  # the output being parsed (#250). Lei.Git keeps the streams apart, so what
  # comes back here is output and nothing else, and the filter is gone rather
  # than kept as a guard against something that can no longer happen.
  @spec git_log_split(Lei.Git.Repository.t(), [String.t()]) :: [String.t()]
  defp git_log_split(repo, args) do
    Lei.Git.run!(repo, ["log" | args])
    |> String.split("\n")
  end
end
