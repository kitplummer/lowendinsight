defmodule Lei.CommitSubstance do
  @moduledoc """
  Decides whether a commit carries information about a project's maintenance (#244).

  Commit currency measures time since the last commit of any kind, which makes
  it resettable by things that say nothing about whether anyone is paying
  attention: a README typo, a license year bump, a merged Dependabot PR. A
  repository with no human involvement for a year can report `low` on the
  strength of automation alone -- and because that is true at any threshold,
  tightening the levels would not reach it.

  The same distinction already exists on the contributor axis.
  `contributor_count` counts everyone who ever pushed; `functional_contributors`
  counts those carrying a real share of the work. Contributors got their filter.
  This is the one currency never had.

  A commit is not substantive when either holds:

    * its author classifies as a bot, which `Lei.AgenticDetector` already
      recognises -- Dependabot, Renovate, github-actions, release-please
    * every path it touches is documentation or repository metadata

  Note that AI co-authorship does **not** make a commit non-substantive. An
  agent-assisted commit still represents a person deciding the project needed
  changing; `agentic_classification` is the metric that speaks to that, and
  conflating the two would answer a different question than this one asks.
  """

  alias Lei.AgenticDetector

  @doc_exact ~w(
    README README.md README.rst README.txt
    LICENSE LICENSE.md LICENCE COPYING NOTICE
    CONTRIBUTING CONTRIBUTING.md CHANGELOG CHANGELOG.md HISTORY.md
    AUTHORS MAINTAINERS CODEOWNERS CODE_OF_CONDUCT.md SECURITY.md
    .gitignore .gitattributes .editorconfig
  )

  @doc_extensions ~w(.md .rst .adoc .txt)

  @doc_prefixes ~w(docs/ doc/ .github/ website/ examples/)

  @doc """
  A single commit, as `%{author_name:, author_email:, files:}`.

  An empty `files` list is deliberately non-substantive: a commit that changed
  no path -- an empty commit, or a merge recorded with no diff of its own --
  tells us nothing about whether the code is being maintained. `Enum.all?/2`
  would return `true` for it either way, so this is stated rather than left to
  fall out of a vacuous truth.
  """
  @spec substantive?(map) :: boolean
  def substantive?(%{files: files}) when files == [], do: false

  def substantive?(%{author_name: name, author_email: email, files: files}) do
    case AgenticDetector.classify_contributor(name || "", email || "") do
      :bot -> false
      _ -> not Enum.all?(files, &documentation?/1)
    end
  end

  def substantive?(_), do: false

  @doc """
  Whether a repository path is documentation or metadata rather than the work.
  """
  @spec documentation?(String.t()) :: boolean
  def documentation?(path) when is_binary(path) do
    trimmed = String.trim(path)
    base = Path.basename(trimmed)
    downcased = String.downcase(trimmed)

    cond do
      trimmed == "" -> true
      base in @doc_exact -> true
      Enum.any?(@doc_prefixes, &String.starts_with?(downcased, &1)) -> true
      Enum.any?(@doc_extensions, &String.ends_with?(downcased, &1)) -> true
      true -> false
    end
  end

  def documentation?(_), do: true

  @doc """
  Parses `git log --name-only` output written with the record format this
  module expects, newest commit first.

  Records are separated by \\x1e and header fields by \\x1f, because both are
  bytes git will not emit inside a path, an address or a date. Splitting on a
  printable delimiter would break on the first filename containing it.

  `warning:` lines are dropped for the same reason `GitModule.git_log_split/2`
  drops them: git writes them onto the same stream as the output.
  """
  @spec parse_log(String.t()) :: [map]
  def parse_log(output) when is_binary(output) do
    output
    |> String.split("\x1e", trim: true)
    |> Enum.map(&parse_record/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_record(record) do
    [header | rest] = String.split(record, "\n")

    case String.split(header, "\x1f") do
      [sha, date, name, email] ->
        %{
          sha: sha,
          date: date,
          author_name: name,
          author_email: email,
          files:
            rest
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == "" or String.contains?(&1, "warning:")))
        }

      _ ->
        nil
    end
  end
end
