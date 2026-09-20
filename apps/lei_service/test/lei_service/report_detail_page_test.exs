defmodule LeiService.ReportDetailPageTest do
  @moduledoc """
  One repository's report is a readable page of its own.

  The report page and the trending table both showed a report as a 17-column
  table row, with the full JSON tree squeezed into its last cell -- unreadable
  on a laptop and on a phone. The report page now lays the report out in
  sections, with the full JSON full-width below, and trending's "view" opens
  that page for the repository (its report is cached by the trending run, so
  the page is served from cache).
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias LeiService.Datastore

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp report(url, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base = %{
      "header" => %{
        "uuid" => "detail",
        "start_time" => now,
        "end_time" => now,
        "library_version" => "0.9.1",
        "source_client" => "lei-get",
        "repo" => url
      },
      "data" => %{
        "repo" => url,
        # The top-level risk is the worst of `results`, so a critical
        # functional-contributors verdict forces it. It read "high" here until
        # #242 began recomputing the rollup on a cache read and caught the
        # disagreement: `determine_toplevel_risk/1` is a maximum, so no real
        # analysis could have produced the report this fixture described.
        "risk" => "critical",
        "repo_size" => 2048,
        "git" => %{
          "default_branch" => "refs/remotes/origin/main",
          "last_commit_date" => "2026-08-02T20:07:48-07:00",
          "total_commits_on_default_branch" => 112,
          "hash" => "3ac24e1f"
        },
        "files" => %{
          "has_readme" => true,
          "has_license" => false,
          "has_contributing" => true,
          "binary_files_count" => 3,
          "total_file_count" => 466
        },
        "results" => %{
          "contributor_count" => 2,
          "contributor_risk" => "high",
          "functional_contributors" => 1,
          "functional_contributors_risk" => "critical",
          "commit_currency_weeks" => 6,
          "commit_currency_risk" => "low",
          "large_recent_commit_risk" => "low",
          "recent_commit_size_in_percent_of_codebase" => 0.00128,
          "sbom_risk" => "medium",
          "agentic_classification" => "human",
          "agentic_contribution_ratio" => 0.0,
          "top10_contributors" => [
            %{
              "name" => "Ada Contributor",
              "email" => "ada@example.com",
              "contributions" => 90,
              "merges" => 4,
              "last_contribution_date" => "2026-08-01T00:00:00Z",
              "classification" => "human"
            }
          ]
        },
        "config" => %{"critical_contributor_level" => 2, "high_currency_level" => 52}
      }
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(a, b) do
    Map.merge(a, b, fn _k, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)
  end

  defp detail_page(report) do
    url = report["data"]["repo"]
    Datastore.write_to_cache(url, report)
    on_exit(fn -> Datastore.delete_from_cache(url) end)

    conn =
      conn(:get, "/url=" <> URI.encode_www_form(url)) |> LeiService.Endpoint.call(@opts)

    assert conn.status == 200, conn.resp_body
    conn.resp_body
  end

  defp url, do: "https://github.com/kitplummer/detail-#{System.unique_integer([:positive])}"

  test "the report is laid out in sections, not a table row" do
    body = detail_page(report(url()))

    for text <- [
          "Overall risk",
          "Contributors",
          "Functional contributors",
          "Commit currency",
          "Large recent commit",
          "SBOM",
          "Agentic",
          "Repository",
          "Top contributors",
          "Ada Contributor",
          "Scoring thresholds",
          "Full report (JSON)"
        ] do
      assert body =~ text, "the page is missing #{inspect(text)}"
    end

    refute body =~ "display_report("
    refute body =~ "jsonTree"
  end

  test "values read as values" do
    body = detail_page(report(url()))

    # The branch without its remote-tracking prefix, and the recent commit as
    # a percentage rather than a fraction.
    assert body =~ ~r/>\s*main\s*</
    refute body =~ "refs/remotes/origin/main<"
    assert body =~ "0.13%"
  end

  test "the report is still machine-readable in the page, as the canary reads it" do
    body = detail_page(report(url()))

    # scripts/canary.sh greps the page for these.
    assert body =~ ~s("risk":"critical")
    assert body =~ ~s("contributor_count":2)
    assert body =~ ~s(<script type="application/json" id="report-data">)
  end

  test "repository-controlled text is escaped" do
    hostile = "</script><script>alert(1)</script>"

    body =
      detail_page(
        report(url(), %{
          "data" => %{
            "git" => %{"default_branch" => hostile},
            "results" => %{
              "top10_contributors" => [%{"name" => hostile, "contributions" => 1}]
            }
          }
        })
      )

    refute body =~ "<script>alert(1)"
    assert body =~ "&lt;/script&gt;&lt;script&gt;alert(1)"
  end

  test "the project is linked only when its URL is http or https" do
    body = detail_page(report(url()))
    assert body =~ ~r/<a [^>]*href="https:\/\/github\.com\/kitplummer\/detail-/

    assert LeiService.ReportView.project_href("javascript:alert(1)") == nil

    assert LeiService.ReportView.project_href("https://github.com/o/r") ==
             "https://github.com/o/r"
  end

  describe "trending" do
    @js File.read!(Path.join(File.cwd!(), "priv/static/js/endpoints.js"))
    @language File.read!(Path.join(File.cwd!(), "priv/templates/language.html.eex"))

    test "view opens the report page for the repository" do
      assert @js =~ ~r/"\/url=" \+ encodeURIComponent\(/
      refute @js =~ "view_json_button"
      refute @js =~ "jsonTree"
    end

    test "the trending page no longer loads the JSON tree viewer" do
      refute @language =~ "jsonTree"
    end
  end
end
