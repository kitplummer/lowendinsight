defmodule LeiService.MonitorMetricsFetchTest do
  @moduledoc """
  The monitor reads /metrics once, as a confirmed probe, and every check reads
  that copy.

  On 2026-11-02 at 08:35Z the monitor emailed for one /metrics request that
  timed out. Seven steps each fetched /metrics themselves with a bare `curl`,
  none under `scripts/ops/confirm.sh`, so one slow response failed the run --
  and failed it silently: `METRICS=$(curl ...)` under the step's `bash -e`
  exits 28 with no message at all. The next run was green.

  Fetching once also means the checks agree with each other: seven fetches
  were seven different moments, and a check could pass on one response while
  its neighbour failed on another.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @fetch Path.join(@root, "scripts/ops/fetch-metrics.sh")
  @confirm Path.join(@root, "scripts/ops/confirm.sh")
  @monitor Path.join(@root, ".github/workflows/monitor.yml")

  @body """
  # TYPE lei_build_info gauge
  lei_build_info{sha="abc",lei_version="0.16.0"} 1
  lei_queue_available 0
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "metrics-fetch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, out: Path.join(dir, "metrics.txt")}
  end

  # A `curl` on PATH that answers call N with the Nth of `answers`:
  # :ok (the body above), :timeout (exit 28, curl's), :http_error (exit 22,
  # what --fail gives a 5xx), :empty, or a binary served as the body.
  defp stub_curl(dir, answers) do
    Enum.with_index(answers, 1)
    |> Enum.each(fn {answer, n} ->
      {body, code} =
        case answer do
          :ok -> {@body, 0}
          :timeout -> {"", 28}
          :http_error -> {"", 22}
          :empty -> {"", 0}
          body when is_binary(body) -> {body, 0}
        end

      File.write!(Path.join(dir, "body.#{n}"), body)
      File.write!(Path.join(dir, "code.#{n}"), "#{code}")
    end)

    File.write!(Path.join(dir, "curl"), """
    #!/usr/bin/env bash
    n=$(( $(cat "#{dir}/calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "#{dir}/calls"
    echo "$*" > "#{dir}/args.$n"
    cat "#{dir}/body.$n"
    exit "$(cat "#{dir}/code.$n")"
    """)

    File.chmod!(Path.join(dir, "curl"), 0o755)
  end

  defp run(dir, args) do
    System.cmd("bash", args,
      env: [{"PATH", "#{dir}:#{System.get_env("PATH")}"}, {"LEI_CONFIRM_WAIT", "0"}],
      stderr_to_stdout: true
    )
  end

  defp fetch(dir, out), do: run(dir, [@fetch, "https://example.test", out])

  defp confirmed(dir, out),
    do: run(dir, [@confirm, "metrics", @fetch, "https://example.test", out])

  describe "fetching" do
    test "saves the response where the checks read it", %{dir: dir, out: out} do
      stub_curl(dir, [:ok])

      assert {_, 0} = fetch(dir, out)
      assert File.read!(out) == @body
      assert File.read!(Path.join(dir, "args.1")) =~ "https://example.test/metrics"
    end

    test "a timeout fails and says so, rather than exiting 28 in silence", %{dir: dir, out: out} do
      stub_curl(dir, [:timeout])

      assert {msg, code} = fetch(dir, out)
      assert code != 0
      assert msg =~ "::error::"
      assert msg =~ "curl exit 28"
    end

    test "an error status fails", %{dir: dir, out: out} do
      stub_curl(dir, [:http_error])
      assert {_, code} = fetch(dir, out)
      assert code != 0
    end

    # An empty or foreign body read by the checks downstream looks like every
    # gauge being absent, and several of those checks treat absent as a
    # warning on an older release.
    test "an empty response fails", %{dir: dir, out: out} do
      stub_curl(dir, [:empty])
      assert {msg, code} = fetch(dir, out)
      assert code != 0
      assert msg =~ "::error::"
    end

    test "a response that is not lei's metrics fails", %{dir: dir, out: out} do
      stub_curl(dir, ["<html>502 Bad Gateway</html>\n"])
      assert {msg, code} = fetch(dir, out)
      assert code != 0
      assert msg =~ "::error::"
    end

    test "a failed fetch leaves no copy behind to be read as current", %{dir: dir, out: out} do
      File.write!(out, @body)
      stub_curl(dir, [:timeout])

      assert {_, code} = fetch(dir, out)
      assert code != 0
      refute File.exists?(out)
    end
  end

  describe "as the monitor runs it" do
    test "the 2026-11-02 timeout clears on re-check and the run passes", %{dir: dir, out: out} do
      stub_curl(dir, [:timeout, :ok])

      assert {msg, 0} = confirmed(dir, out)
      assert msg =~ "::warning::metrics failed once"
      assert File.read!(out) == @body
    end

    test "/metrics down for both attempts still fails the run", %{dir: dir, out: out} do
      stub_curl(dir, [:timeout, :timeout])

      assert {msg, code} = confirmed(dir, out)
      assert code != 0
      assert msg =~ "::error::metrics failed twice"
    end
  end

  describe "the workflow" do
    test "fetches /metrics once, under confirm.sh" do
      assert File.read!(@monitor) =~
               ~s(scripts/ops/confirm.sh metrics scripts/ops/fetch-metrics.sh https://lowendinsight.dev "$RUNNER_TEMP/metrics.txt")
    end

    test "no check fetches /metrics for itself" do
      direct =
        File.read!(@monitor)
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ "curl" and line =~ "/metrics" end)

      assert direct == [],
             "these lines fetch /metrics outside the confirmed fetch, so one slow response fails the run: " <>
               inspect(direct)
    end
  end
end
