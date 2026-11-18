defmodule LeiService.AdoptionReportTest do
  @moduledoc """
  The weekly adoption report reads what `Lei.Metrics` publishes, and refuses to
  report what it could not read.

  `Lei.Adoption` counted analysis calls by client and `/metrics` published them,
  but nothing read them. `scripts/ops/adoption-report.sh` renders them for the
  running `adoption-report` issue. These drive it with the metrics the service
  actually emits, so a renamed gauge or a new bucket fails here rather than in
  a report that quietly reads zero.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/ops/adoption-report.sh")
  @workflow Path.join(@root, ".github/workflows/adoption-report.yml")

  setup do
    dir = Path.join(System.tmp_dir!(), "adoption-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp report(dir, metrics, args \\ [], env \\ []) do
    path = Path.join(dir, "metrics.txt")
    File.write!(path, metrics)
    System.cmd("bash", [@script, path | args], stderr_to_stdout: true, env: env)
  end

  defp data(out) do
    [_, json] = Regex.run(~r/<!-- adoption-data[^\n]*\n```json\n(\{.*\})\n```/, out)
    Poison.decode!(json)
  end

  test "reads every bucket from the metrics the service emits", %{dir: dir} do
    Lei.Adoption.record_bucket("mcp-remote", "test:report")
    {:ok, month} = Lei.Adoption.window(30)

    {out, 0} = report(dir, Lei.Metrics.collect())

    for bucket <- Lei.Adoption.buckets() do
      assert out =~ "| `#{bucket}` |", "the report has no row for #{bucket}"
    end

    assert data(out)["calls_30d"] == month
  end

  test "reports distinct callers alongside calls", %{dir: dir} do
    Lei.Adoption.record_bucket("mcp-remote", "test:#{System.unique_integer([:positive])}")
    {:ok, %{clients: week, external: external}} = Lei.Adoption.callers(7)
    {:ok, %{clients: month}} = Lei.Adoption.callers(30)

    {out, 0} = report(dir, Lei.Metrics.collect())

    assert out =~ "callers, 7 days"
    assert data(out)["callers_7d"] == week
    assert data(out)["callers_30d"] == month
    assert data(out)["external_callers_7d"] == external
    assert out =~ "**External callers, last 7 days:** #{external};"
  end

  test "a caller count missing from /metrics is a failure, not a zero", %{dir: dir} do
    metrics =
      Lei.Metrics.collect()
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~r/^lei_adoption_callers_7d\{client="agent"\}/))
      |> Enum.join("\n")

    {out, code} = report(dir, metrics)

    assert code != 0
    assert out =~ ~s(client "agent")
  end

  test "a missing external caller count is a failure, not a zero", %{dir: dir} do
    metrics =
      Lei.Metrics.collect()
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~r/^lei_adoption_external_callers_7d /))
      |> Enum.join("\n")

    {out, code} = report(dir, metrics)

    assert code != 0
    assert out =~ "external callers"
  end

  test "knows exactly the buckets Lei.Adoption counts" do
    [_, list] = Regex.run(~r/^BUCKETS="([^"]+)"/m, File.read!(@script))
    assert String.split(list) == Lei.Adoption.buckets()
  end

  test "an unreadable counter is a failure, not a report of zero", %{dir: dir} do
    {out, code} = report(dir, "lei_adoption_readable 0\n")

    assert code != 0
    # Said as unreadable, not as a missing bucket: the fix for each differs.
    assert out =~ "the adoption counters could not be read"
    refute out =~ "| client |"
  end

  test "a bucket missing from /metrics is a failure, not a zero", %{dir: dir} do
    metrics =
      Lei.Metrics.collect()
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~s(client="browser")))
      |> Enum.join("\n")

    {out, code} = report(dir, metrics)

    assert code != 0
    assert out =~ ~s(client "browser")
  end

  test "last week's report gives the change", %{dir: dir} do
    metrics = Lei.Metrics.collect()
    {first, 0} = report(dir, metrics, [], [{"ADOPTION_REPORT_DATE", "2026-11-17"}])
    File.write!(Path.join(dir, "previous.md"), first)

    Lei.Adoption.record_bucket("other", "test:report")
    Lei.Adoption.record_bucket("other", "test:report")

    {second, 0} =
      report(dir, Lei.Metrics.collect(), [Path.join(dir, "previous.md")], [
        {"ADOPTION_REPORT_DATE", "2026-11-24"}
      ])

    assert second =~ "change since 2026-11-17"
    assert second =~ ~r/\| `other` \| \d+ \| \d+ \| \d+ \| \d+ \| \+2 \|/
  end

  test "the issue body explains itself and still carries the data", %{dir: dir} do
    {out, 0} = report(dir, Lei.Metrics.collect(), ["--intro"])

    assert out =~ "Do not close this issue"
    assert data(out)["calls_30d"]
  end

  test "the workflow keeps one running issue and can write to it" do
    workflow = File.read!(@workflow)

    assert workflow =~ "issues: write"
    assert workflow =~ "labels=adoption-report&state=open"

    assert workflow =~
             ~s(scripts/ops/adoption-report.sh "$RUNNER_TEMP/metrics.txt" "$RUNNER_TEMP/previous.md" --intro)

    assert workflow =~ "scripts/ops/confirm.sh metrics scripts/ops/fetch-metrics.sh"
  end
end
