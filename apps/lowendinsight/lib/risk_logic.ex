# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule RiskLogic do
  @moduledoc """
  RiskLogic contains the functionality for determining risk based on
  numeric input values
  """

  @doc """
  sbom_risk/1: returns text risk level for identified sbom_risk
  """
  @spec sbom_risk() :: {:ok, String.t()}
  def sbom_risk() do
    Application.fetch_env(:lowendinsight, :sbom_risk_level)
  end

  @doc """
  contributor_risk/1: returns text enumeration for count
  """
  @spec contributor_risk(non_neg_integer) :: {:ok, String.t()}
  def contributor_risk(contributor_count) do
    critical_contributor_level =
      if Application.fetch_env(:lowendinsight, :critical_contributor_level) == :error,
        do: 2,
        else: Application.fetch_env!(:lowendinsight, :critical_contributor_level)

    high_contributor_level =
      if Application.fetch_env(:lowendinsight, :high_contributor_level) == :error,
        do: 3,
        else: Application.fetch_env!(:lowendinsight, :high_contributor_level)

    medium_contributor_level =
      if Application.fetch_env(:lowendinsight, :medium_contributor_level) == :error,
        do: 5,
        else: Application.fetch_env!(:lowendinsight, :medium_contributor_level)

    cond do
      contributor_count < critical_contributor_level ->
        {:ok, "critical"}

      contributor_count < high_contributor_level ->
        {:ok, "high"}

      contributor_count < medium_contributor_level ->
        {:ok, "medium"}

      contributor_count >= medium_contributor_level ->
        {:ok, "low"}
    end
  end

  @doc """
  commit_currency_risk/1: returns text enumeration for commit currency risk
  """
  @spec commit_currency_risk(non_neg_integer) :: {:ok, String.t()}
  def commit_currency_risk(delta_in_weeks) do
    medium_currency_level =
      if Application.fetch_env(:lowendinsight, :medium_currency_level) == :error,
        do: 26,
        else: Application.fetch_env!(:lowendinsight, :medium_currency_level)

    high_currency_level =
      if Application.fetch_env(:lowendinsight, :high_currency_level) == :error,
        do: 52,
        else: Application.fetch_env!(:lowendinsight, :high_currency_level)

    critical_currency_level =
      if Application.fetch_env(:lowendinsight, :critical_currency_level) == :error,
        do: 52,
        else: Application.fetch_env!(:lowendinsight, :critical_currency_level)

    cond do
      delta_in_weeks < medium_currency_level ->
        {:ok, "low"}

      delta_in_weeks < high_currency_level ->
        {:ok, "medium"}

      delta_in_weeks < critical_currency_level ->
        {:ok, "high"}

      delta_in_weeks >= critical_currency_level ->
        {:ok, "critical"}
    end
  end

  @doc """
  functional_commit_currency_risk/1: the risk from time since the last commit
  that carried information (#244).

  Configured separately from `commit_currency_risk/1` on purpose. The last
  substantive commit is always at or before the last commit of any kind, so
  under shared thresholds this metric could only ever be the worse of the two
  -- and since the report's verdict is a maximum, the plain metric could never
  be the one that decides. Tuning one would silently move the other. These are
  the levels that actually govern the verdict; `commit_currency_*` is kept as
  it was so the two remain comparable in a report.

  The fallbacks below are deliberately distinct from each other. Where
  `commit_currency_risk/1` falls back to 52 for both its high and critical
  levels -- making `"high"` unreachable for a library consumer who configures
  nothing -- every level here is reachable without configuration.
  """
  @spec functional_commit_currency_risk(non_neg_integer) :: {:ok, String.t()}
  def functional_commit_currency_risk(delta_in_weeks) do
    medium = level(:medium_functional_currency_level, 13)
    high = level(:high_functional_currency_level, 26)
    critical = level(:critical_functional_currency_level, 52)

    cond do
      delta_in_weeks < medium -> {:ok, "low"}
      delta_in_weeks < high -> {:ok, "medium"}
      delta_in_weeks < critical -> {:ok, "high"}
      true -> {:ok, "critical"}
    end
  end

  defp level(key, default) do
    case Application.fetch_env(:lowendinsight, key) do
      :error -> default
      {:ok, value} when is_integer(value) -> value
      {:ok, value} when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  end

  @doc """
  last_commit_size_risk/1: returns a text enumeration for the risk based on the size of the last commit
  """
  @spec commit_change_size_risk(non_neg_integer) :: {:ok, String.t()}
  def commit_change_size_risk(change_percent) do
    medium_large_commit_level =
      if Application.fetch_env(:lowendinsight, :medium_large_commit_level) == :error,
        do: 0.2,
        else: Application.fetch_env!(:lowendinsight, :medium_large_commit_level)

    high_large_commit_level =
      if Application.fetch_env(:lowendinsight, :high_large_commit_level) == :error,
        do: 0.3,
        else: Application.fetch_env!(:lowendinsight, :high_large_commit_level)

    critical_large_commit_level =
      if Application.fetch_env(:lowendinsight, :critical_large_commit_level) == :error,
        do: 0.5,
        else: Application.fetch_env!(:lowendinsight, :critical_large_commit_level)

    cond do
      change_percent < medium_large_commit_level ->
        {:ok, "low"}

      change_percent < high_large_commit_level ->
        {:ok, "medium"}

      change_percent < critical_large_commit_level ->
        {:ok, "high"}

      change_percent >= critical_large_commit_level ->
        {:ok, "critical"}
    end
  end

  @doc """
  functional_contributors_risk/1: returns the enumerated risk based on input contributors list
  """
  @spec functional_contributors_risk(non_neg_integer) :: {:ok, String.t()}
  def functional_contributors_risk(contributors) do
    medium_functional_contributors_level =
      if Application.fetch_env(:lowendinsight, :medium_functional_contributors_level) == :error,
        do: 5,
        else: Application.fetch_env!(:lowendinsight, :medium_functional_contributors_level)

    high_functional_contributors_level =
      if Application.fetch_env(:lowendinsight, :high_functional_contributors_level) == :error,
        do: 5,
        else: Application.fetch_env!(:lowendinsight, :high_functional_contributors_level)

    critical_functional_contributors_level =
      if Application.fetch_env(:lowendinsight, :critical_functional_contributors_level) == :error,
        do: 2,
        else: Application.fetch_env!(:lowendinsight, :critical_functional_contributors_level)

    cond do
      contributors >= medium_functional_contributors_level ->
        {:ok, "low"}

      contributors >= high_functional_contributors_level ->
        {:ok, "medium"}

      contributors >= critical_functional_contributors_level ->
        {:ok, "high"}

      contributors < critical_functional_contributors_level ->
        {:ok, "critical"}
    end
  end

  @doc """
  agentic_classification/1: returns classification label for agentic contribution ratio.
  Ratio represents the fraction of commits from bots or AI-assisted contributors.
  Returns "human", "mixed", or "agent".
  """
  @spec agentic_classification(float) :: {:ok, String.t()}
  def agentic_classification(ratio) do
    high_agentic_level =
      if Application.fetch_env(:lowendinsight, :high_agentic_level) == :error,
        do: 0.7,
        else: Application.fetch_env!(:lowendinsight, :high_agentic_level)

    medium_agentic_level =
      if Application.fetch_env(:lowendinsight, :medium_agentic_level) == :error,
        do: 0.3,
        else: Application.fetch_env!(:lowendinsight, :medium_agentic_level)

    cond do
      ratio > high_agentic_level ->
        {:ok, "agent"}

      ratio >= medium_agentic_level ->
        {:ok, "mixed"}

      ratio < medium_agentic_level ->
        {:ok, "human"}
    end
  end
end
