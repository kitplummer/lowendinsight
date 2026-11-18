defmodule LeiService.CanaryMcpTest do
  @moduledoc """
  The canary analyses through /mcp, and fails when that analysis did nothing.

  The smoke test reaches /mcp only with calls that cost nothing, so an MCP
  analysis that cloned nothing, hung or answered with an empty shell left every
  check green. These run `canary.sh` against a `curl` stub that answers /mcp as
  the server would, and read only the canary's MCP section.
  """
  use ExUnit.Case, async: true

  @canary Path.expand("../../../../scripts/canary.sh", __DIR__)
  @repo "https://github.com/kitplummer/lita-cron"

  setup do
    dir = Path.join(System.tmp_dir!(), "canary-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp report(fields \\ [], cache \\ %{"hits" => 0, "misses" => 1}) do
    results = Map.merge(%{"contributor_count" => 3}, Map.new(fields))

    %{
      "state" => "complete",
      "metadata" => %{"cache_status" => cache},
      "report" => %{
        "repos" => [%{"data" => %{"repo" => @repo, "risk" => "medium", "results" => results}}]
      }
    }
  end

  defp tool(structured, error? \\ false) do
    result = %{
      "content" => [%{"type" => "text", "text" => "x"}],
      "structuredContent" => structured
    }

    result = if error?, do: Map.put(result, "isError", true), else: result
    Poison.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
  end

  # analyze_repositories answers with `analyze`; get_analysis with `collect`;
  # the cache invalidation succeeds. Every other request gets an empty answer.
  @keys [{"LEI_SMOKE_API_KEY", "lei_test"}, {"LEI_ADMIN_API_KEY", "lei_admin"}]

  defp run(dir, analyze, collect \\ nil, env \\ @keys) do
    File.write!(Path.join(dir, "analyze.json"), analyze)
    File.write!(Path.join(dir, "collect.json"), collect || analyze)

    File.write!(Path.join(dir, "curl"), """
    #!/usr/bin/env bash
    args="$*"
    case "$args" in
      */mcp*analyze_repositories*) cat "#{dir}/analyze.json" ;;
      */mcp*get_analysis*) cat "#{dir}/collect.json" ;;
      */v1/cache/invalidate*) printf "${STUB_INVALIDATE:-200}" ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(dir, "curl"), 0o755)

    {out, _} =
      System.cmd("bash", [@canary, "http://stub.test"],
        env: [
          {"PATH", "#{dir}:#{System.get_env("PATH")}"},
          {"CANARY_ANALYZE_TIMEOUT", "10"} | env
        ],
        stderr_to_stdout: true
      )

    # The MCP section only.
    [_, section] = String.split(out, "analyze through MCP", parts: 2)
    [section | _] = String.split(section, "the other main-page destinations")
    section
  end

  test "a complete report passes", %{dir: dir} do
    out = run(dir, tool(report()))

    assert out =~ "analyze_repositories completes"
    assert out =~ "MCP report has contributors"
    refute out =~ "FAIL"
  end

  test "outlasting the tool's wait is collected with get_analysis", %{dir: dir} do
    incomplete =
      tool(%{"state" => "incomplete", "uuid" => "00000000-0000-4000-8000-000000000001"})

    out = run(dir, incomplete, tool(report()))

    assert out =~ "analyze_repositories completes"
    refute out =~ "FAIL"
  end

  test "a tool error fails", %{dir: dir} do
    out = run(dir, tool(%{"error" => "free_tier_quota_exceeded"}, true))

    assert out =~ "FAIL"
    assert out =~ "tool error"
  end

  test "a report with no contributors fails: the analysis did nothing", %{dir: dir} do
    out = run(dir, tool(report(contributor_count: 0)))

    assert out =~ "FAIL"
    assert out =~ "contributor_count is 0"
  end

  # The 2026-11-17 dispatch came back in 0s after invalidating, and timing
  # could not say whether that was an analysis. The report's own cache status
  # can.
  test "a report served from the cache fails, however it was asked for", %{dir: dir} do
    out = run(dir, tool(report([], %{"hits" => 1, "misses" => 0})))

    assert out =~ "FAIL"
    assert out =~ "cache hit"
  end

  test "a report that does not say whether it was cached fails", %{dir: dir} do
    out = run(dir, tool(report() |> Map.delete("metadata")))

    assert out =~ "FAIL"
    assert out =~ "does not say whether it came from the cache"
  end

  test "a failed invalidation is reported", %{dir: dir} do
    out =
      run(dir, tool(report()), nil, [
        {"LEI_SMOKE_API_KEY", "lei_test"},
        {"LEI_ADMIN_API_KEY", "x"},
        {"STUB_INVALIDATE", "500"}
      ])

    assert out =~ "FAIL"
    assert out =~ "cache invalidated again for the MCP analysis"
  end

  test "no key fails in strict mode rather than skipping", %{dir: dir} do
    out = run(dir, tool(report()), nil, [{"CANARY_STRICT", "1"}])

    assert out =~ "FAIL"
    assert out =~ "LEI_SMOKE_API_KEY is not set"
  end
end
