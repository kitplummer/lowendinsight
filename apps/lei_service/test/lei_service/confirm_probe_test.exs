defmodule LeiService.ConfirmProbeTest do
  @moduledoc """
  A production probe fails the monitor only when its failure persists.

  A failed GitHub run means the system is unhealthy; anything that emails
  without that being true teaches the reader to ignore the email. From
  2026-10-10 to 10-24 the monitor emailed for one empty homepage fetch, one
  SSL connect error and a canary false failure, each gone by the next run.
  Probes against production go through `scripts/ops/confirm.sh`: a failure is
  re-checked after a pause and fails the run only if it fails again. The first
  failure is still shown, as a warning on the run.

  Distinct from retrying tests, which this repository forbids: a test suite is
  deterministic and a retry hides ordering bugs. A probe crosses the internet,
  and the question it answers -- is production down -- is about a state that
  persists.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/ops/confirm.sh")
  @monitor Path.join(@root, ".github/workflows/monitor.yml")

  setup do
    dir = Path.join(System.tmp_dir!(), "confirm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A probe that fails its first `failures` runs with exit `code`.
  defp probe(dir, failures, code \\ 1) do
    path = Path.join(dir, "probe")

    File.write!(path, """
    #!/usr/bin/env bash
    n=$(( $(cat "#{dir}/calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "#{dir}/calls"
    echo "probe run $n args: $*"
    [ "$n" -gt #{failures} ] || { echo "::error::probe broke"; exit #{code}; }
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp confirm(dir, probe) do
    {out, code} =
      System.cmd("bash", [@script, "canary", probe, "https://example.test"],
        env: [{"LEI_CONFIRM_WAIT", "0"}],
        stderr_to_stdout: true
      )

    {out, code, String.trim(File.read!(Path.join(dir, "calls")))}
  end

  test "a failure that clears on re-check passes, and says it happened", %{dir: dir} do
    {out, code, calls} = confirm(dir, probe(dir, 1))

    assert code == 0
    assert calls == "2"
    assert out =~ "::warning::canary failed once"
    assert out =~ "args: https://example.test", "arguments were not passed through"

    refute out =~ "::error::",
           "a failure that cleared left an error annotation on a green run:\n#{out}"
  end

  test "a failure that persists fails, with the probe's own exit code", %{dir: dir} do
    {out, code, calls} = confirm(dir, probe(dir, 99, 7))

    assert code == 7
    assert calls == "2"
    assert out =~ "::error::canary failed twice"
    assert out =~ "::error::probe broke", "the persisting failure's own errors were hidden"
  end

  test "a pass is not re-run", %{dir: dir} do
    {_out, 0, calls} = confirm(dir, probe(dir, 0))
    assert calls == "1"
  end

  test "the monitor confirms its production probes" do
    monitor = File.read!(@monitor)

    for {name, probe} <- [
          {"canary", "scripts/canary.sh https://lowendinsight.dev"},
          {"smoke", "./scripts/smoke-test.sh https://lowendinsight.dev"},
          {"readiness", "scripts/ops/check-readiness.sh https://lowendinsight.dev"}
        ] do
      assert monitor =~ "scripts/ops/confirm.sh #{name} #{probe}",
             "the #{name} probe fails the monitor on a single attempt"
    end
  end
end
