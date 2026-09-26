defmodule LeiService.SmokeDiagnosticsTest do
  @moduledoc """
  When the smoke suite dies, it has to say where.

  On 2026-09-26 at 19:36 the monitor failed on `Smoke test against production`
  with `Process completed with exit code 28` and nothing else. 28 is curl's
  timeout, and `smoke-test.sh` runs under `set -euo pipefail`, so the first curl
  to exceed `--max-time` killed the script before it printed a summary or named
  the request. The page said `failed checks: smoke` and that was the entirety of
  what anyone had to work from. Production was answering in under 200ms at the
  time and the next run passed, so whatever it was is gone and unknowable.

  This asserts the diagnostics behaviourally -- by running the script against a
  closed port and reading what it says -- rather than by grepping it for a trap.
  A trap that is installed but reports nothing useful would pass a grep.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Port 1 refuses instantly, so this costs milliseconds rather than a timeout.
  @unreachable "http://127.0.0.1:1"

  defp run_smoke do
    {output, status} =
      System.cmd("bash", ["scripts/smoke-test.sh", @unreachable],
        cd: @root,
        stderr_to_stdout: true,
        env: [{"LEI_SMOKE_API_KEY", "not-a-real-key"}]
      )

    {output, status}
  end

  test "a failed request names itself, rather than only an exit code" do
    {output, status} = run_smoke()

    refute status == 0, "the script passed against a closed port"

    assert output =~ "Smoke test aborted",
           "the script died without saying it had aborted:\n#{output}"

    # Scoped to the diagnostic. The banner at the top also carries the URL, so
    # asserting against the whole output passed while the diagnostic said
    # nothing -- the same mistake as matching the wrong occurrence of a string.
    [_, diagnostic] = String.split(output, "Smoke test aborted", parts: 2)

    # Fragments that exist only in the echoed command. "curl" alone matched the
    # explanation line ("curl could not connect"), and the host alone matched
    # the "Against:" line -- so the guard passed with the command removed. The
    # mutation smoke-diagnostic-hides-the-request caught that.
    assert diagnostic =~ "curl -s",
           "the diagnostic does not show the request that failed:\n#{diagnostic}"

    assert diagnostic =~ "--max-time",
           "the diagnostic describes the failure without echoing the command:\n#{diagnostic}"

    assert diagnostic =~ "127.0.0.1:1",
           "the diagnostic does not say which host it was talking to:\n#{diagnostic}"

    assert output =~ ~r/line \d+/,
           "no line number, so the failing check cannot be located"
  end

  test "it says what kind of failure it was" do
    {output, _} = run_smoke()

    # Exit 7 here; 28 is the timeout that actually happened in production. Both
    # are mapped, because "exit code 28" told nobody anything.
    assert output =~ ~r/could not connect|timed out|exit 7/,
           "the failure mode is not explained:\n#{output}"
  end

  test "it reports how far it got" do
    {output, _} = run_smoke()

    assert output =~ ~r/\d+ passed.*\d+ failed/,
           "no partial tally, so how much ran is unknown:\n#{output}"
  end

  test "it does not print the API key" do
    # The diagnostic prints the failing command. BASH_COMMAND is unexpanded, so
    # it shows `$API_KEY` rather than its value -- verified, and asserted here
    # because a future version that expands it would leak a credential into
    # every CI log.
    {output, _} = run_smoke()

    refute output =~ "not-a-real-key",
           "the diagnostic expanded the API key into the output"
  end
end
