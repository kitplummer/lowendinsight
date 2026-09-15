defmodule LowendinsightGet.ReportPageInjectionTest do
  @moduledoc """
  Report pages render data that repository owners control, as data.

  A repository's owner chooses its commit author names, its default branch
  name and, through the URL, part of its slug. The report and trending pages
  wrote those into `<script>` blocks with plain EEx: whole reports through
  `Poison.encode!`, which does not escape `<`, and single fields between double
  quotes, which nothing escaped at all. A branch named `x";alert(1)//` or a
  contributor named `</script><script>...` ran script in the reader's browser --
  on the unauthenticated Try It page and on the public trending pages.

  endpoints.js then wrote those same fields into the table with innerHTML, and
  linked the project with whatever URL the report held.

  There is no JavaScript runtime in this suite, so the page is checked by
  structure: hostile data must not add a script element, must not appear
  outside a JSON string, and the script must not use innerHTML.

  The trending page also passed display_row one argument fewer than it takes
  (agentic_classification was added to the function, not to the call), so
  every later argument shifted and json_data arrived undefined -- which is why
  its "view" button did nothing.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias LowendinsightGet.Datastore

  @opts LowendinsightGet.Endpoint.init([])

  @breakout "</script><script>alert(1)</script>"
  @quote_breakout ~s|x";alert(2)//|

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp hostile_report(url) do
    %{
      "data" => %{
        "repo" => url,
        "risk" => "<img src=x onerror=alert(3)>",
        "repo_size" => @breakout,
        "git" => %{
          "default_branch" => @quote_breakout <> @breakout,
          "last_commit_date" => "2026-09-01T00:00:00Z",
          "total_commits_on_default_branch" => 10
        },
        "results" => %{
          "contributor_count" => 1,
          "contributor_risk" => "low",
          "functional_contributors" => 1,
          "functional_contributors_risk" => "low",
          "large_recent_commit_risk" => "low",
          "recent_commit_size_in_percent_of_codebase" => 0.1,
          "commit_currency_weeks" => 1,
          "commit_currency_risk" => "low",
          "sbom_risk" => "low",
          "top10_contributors" => [%{"name" => @breakout, "email" => @quote_breakout}]
        }
      },
      "header" => %{
        "uuid" => "u",
        "start_time" => "2026-09-01T00:00:00Z",
        "end_time" => "2026-09-01T00:00:00Z"
      }
    }
  end

  defp script_tags(body), do: length(Regex.scan(~r/<script\b/i, body))

  defp get(path), do: conn(:get, path) |> LowendinsightGet.Endpoint.call(@opts)

  defp trending_page(repos) do
    language = "zz-injection-#{System.unique_integer([:positive])}"
    uuid = "zz-injection-report-#{System.unique_integer([:positive])}"

    report = %{
      "metadata" => %{"times" => %{"end_time" => "2026-09-01T00:00:00Z"}},
      "report" => %{"uuid" => uuid, "repos" => repos}
    }

    {:ok, _} = Redix.command(:redix, ["SET", uuid, Poison.encode!(report)])
    {:ok, _} = Redix.command(:redix, ["SET", "gh_trending_#{language}_uuid", uuid])

    on_exit(fn -> Redix.command(:redix, ["DEL", uuid, "gh_trending_#{language}_uuid"]) end)

    get("/gh_trending/#{language}")
  end

  describe "the trending page" do
    test "hostile repository data adds no script element" do
      clean = trending_page([hostile_report("https://github.com/kitplummer/clean")])
      baseline = script_tags(clean.resp_body)

      url = "https://github.com/evil/repo"
      page = trending_page([hostile_report(url), hostile_report(url)])

      assert page.status == 200
      # One more repository is exactly one more script element. A breakout
      # adds more: before the fix this page had five.
      assert script_tags(page.resp_body) == baseline + 1
      refute page.resp_body =~ "<script>alert(1)"
      # And the data did reach the page, escaped -- not silently dropped.
      assert page.resp_body =~ "\\u003c/script\\u003e\\u003cscript\\u003ealert(1)"
      # Encoded as a JSON string the quote is `\"`; unescaped, it ends one.
      refute page.resp_body =~ ~r/(?<!\\)";alert\(2\)/
      refute page.resp_body =~ "<img src=x"
    end

    test "each row is rendered by one call carrying the whole report" do
      page = trending_page([hostile_report("https://github.com/kitplummer/one")])

      # The arity mismatch cannot recur if the template passes the report and
      # the script reads the fields.
      assert page.resp_body =~ ~r/display_report\(\s*"kitplummer\/one"\s*,\s*\{/
      refute page.resp_body =~ "display_row("
    end

    test "a language in the path is rendered as text" do
      page = get("/gh_trending/%3Cscript%3Ealert(5)%3C%2Fscript%3E")

      refute page.resp_body =~ "<script>alert(5)"
    end
  end

  describe "the Try It report page" do
    test "a cached hostile report adds no script element" do
      url = "https://github.com/evil/cached-#{System.unique_integer([:positive])}"
      Datastore.write_to_cache(url, hostile_report(url))
      on_exit(fn -> Datastore.delete_from_cache(url) end)

      page = get("/url=" <> URI.encode_www_form(url))

      assert page.status == 200, page.resp_body
      refute page.resp_body =~ "<script>alert(1)"
      # And the data did reach the page, escaped -- not silently dropped.
      assert page.resp_body =~ "\\u003c/script\\u003e\\u003cscript\\u003ealert(1)"
      # Encoded as a JSON string the quote is `\"`; unescaped, it ends one.
      refute page.resp_body =~ ~r/(?<!\\)";alert\(2\)/
      # The report page renders the report server-side, escaped, and keeps a
      # machine-readable copy in a JSON script element.
      assert page.resp_body =~ ~s(<script type="application/json" id="report-data">)
      assert page.resp_body =~ "&lt;/script&gt;&lt;script&gt;alert(1)"
    end
  end

  describe "endpoints.js" do
    @js File.read!(Path.join(File.cwd!(), "priv/static/js/endpoints.js"))

    test "writes no data with innerHTML" do
      refute @js =~ "innerHTML",
             "endpoints.js assigns innerHTML; report fields are attacker-controlled"
    end

    test "links a project only when its URL is http or https" do
      assert @js =~ ~r/function safe_href\(url\) \{\s*return \/\^https\?:/
      refute @js =~ ~r/\.href\s*=\s*project\b/
    end

    test "defines display_report, which both pages call" do
      assert @js =~ ~r/function display_report\(slug, report\)/
    end
  end
end
