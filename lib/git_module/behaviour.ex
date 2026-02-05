# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule GitModule.Behaviour do
  @moduledoc """
  Behaviour definition for GitModule operations.

  This allows for mocking git operations in tests using Mox.
  """

  @type repo :: Git.Repository.t()

  @callback clone_repo(String.t(), String.t()) :: {:ok, repo()} | {:error, String.t()}
  @callback get_repo(String.t()) :: {:ok, repo()} | {:error, String.t()}
  @callback delete_repo(repo()) :: [binary()]
  @callback get_hash(repo()) :: {:ok, String.t()}
  @callback get_default_branch(repo()) :: {:ok, String.t()}
  @callback get_total_commit_count(repo()) :: {:ok, non_neg_integer() | String.t()}
  @callback get_contributor_count(repo()) :: {:ok, non_neg_integer()}
  @callback get_contributors(repo()) :: {:ok, [Contributor.t()]}
  @callback get_contributions_map(repo()) :: {:ok, [%{contributions: non_neg_integer(), name: String.t()}]}
  @callback get_clean_contributions_map(repo()) :: {:ok, list()}
  @callback get_top10_contributors_map(repo()) :: {:ok, [any()]}
  @callback get_contributor_distribution(repo()) :: {:ok, map(), non_neg_integer()}
  @callback get_functional_contributors(repo()) :: {:ok, non_neg_integer(), [any()]}
  @callback get_commit_dates(repo()) :: {:ok, [non_neg_integer()]}
  @callback get_last_commit_date(repo()) :: {:ok, String.t()}
  @callback get_last_contribution_date_by_contributor(repo(), String.t()) :: String.t() | nil
  @callback get_tag_and_commit_dates(repo()) :: {:ok, [list()]}
  @callback get_last_n_commits(repo(), non_neg_integer()) :: {:ok, [any()]}
  @callback get_diff_2_commits(repo(), [any()]) :: {:ok, [String.t()]} | []
  @callback get_total_lines(repo()) :: {:ok, non_neg_integer(), non_neg_integer()}
  @callback get_recent_changes(repo()) :: {:ok, number(), number()}
  @callback get_last_2_delta(repo()) :: {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @callback get_repo_size(repo()) :: {:ok, String.t()}
end
