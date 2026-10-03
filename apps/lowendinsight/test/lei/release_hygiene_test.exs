defmodule Lei.ReleaseHygieneTest do
  @moduledoc """
  The CHANGELOG and the version have to agree with each other.

  Sixteen commits sat unpublished from 2026-09-16 to 2026-10-03, including
  `Lei.CommitSubstance`, `Lei.ReportFreshness` and `Lei.RiskProfile` — the three
  modules that are this library's differentiation. Nothing noticed, because
  every check in CI looks at the tree and the tree was fine.

  It was found by consuming the published package from outside the repository: a
  survey built on `lowendinsight 0.10.0` produced 329 analysed repositories with
  **zero** `functional_commit_currency_weeks`, because the module that computes
  it had never been released. The study measured plain commit currency instead,
  and reported it as the differentiated signal.

  The document said `## 0.10.0 — unreleased` for a version tagged and published
  that day, which is the one-line contradiction that would have given it away.
  These assertions are offline and run in every suite, because
  `@tag :network` is excluded everywhere including CI — a guard that never runs
  is not a guard. The hex comparison is a step in `audit.yml`, which has the
  network and runs daily.
  """
  use ExUnit.Case, async: true

  @changelog Path.expand("../../CHANGELOG.md", __DIR__)
  @mixfile Path.expand("../../mix.exs", __DIR__)

  defp headings do
    @changelog
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "## "))
  end

  defp version do
    [_, v] = Regex.run(~r/version:\s*"([^"]+)"/, File.read!(@mixfile))
    v
  end

  test "the top CHANGELOG section is the version in mix.exs" do
    # A version bump with no entry, or an entry with no bump, is how a release
    # ends up describing something other than what it contains.
    [top | _] = headings()

    assert top =~ version(),
           """
           mix.exs says #{version()} and the newest CHANGELOG section is:

             #{top}

           One of them is wrong.
           """
  end

  test "only the newest section may be unreleased" do
    # `## 0.10.0 — unreleased` survived the release of 0.10.0 and sat there for
    # seventeen days while sixteen commits accumulated behind it. A stale
    # marker is worse than no marker: it says the work is still coming.
    [_top | older] = headings()

    stale = Enum.filter(older, &(String.downcase(&1) =~ "unreleased"))

    assert stale == [],
           """
           These CHANGELOG sections are not the newest and still say unreleased:

             #{Enum.join(stale, "\n  ")}

           A released version gets its date. If the work is genuinely unreleased,
           it belongs in the newest section.
           """
  end

  test "every released section carries a date" do
    # Undated headings below the top are how "when did that ship" becomes
    # unanswerable, and how the previous failure stayed invisible.
    [_top | older] = headings()

    undated =
      Enum.reject(older, fn heading ->
        heading =~ ~r/\d{4}-\d{2}-\d{2}/ or String.downcase(heading) =~ "unreleased"
      end)

    assert undated == [],
           """
           These released CHANGELOG sections have no date:

             #{Enum.join(undated, "\n  ")}
           """
  end
end
