defmodule LeiService.ScriptSigpipeTest do
  @moduledoc """
  A match must read as a match in the operations scripts.

  `printf '%s' "$BODY" | grep -q needle` under `set -o pipefail` is wrong as
  soon as the body is larger than a pipe buffer (64 KB) and the match is not on
  its last line. `grep -q` exits at the first match, `printf` writes into a
  closed pipe, and pipefail makes the pipeline report printf's failure. A
  found needle reads as a missing one.

  The monitor canary failed on "report names the repo" this way on 2026-10-24
  (`printf: write error: Broken pipe` immediately before the FAIL), depending
  only on how large the report page was. That direction fails closed. The same
  shape in `contributor_count":0` and in `secret-scan.sh` fails open: the bad
  thing is found and the check passes.

  A here-string has no second process to fail.
  """
  use ExUnit.Case, async: true

  @scripts Path.expand("../../../../scripts", __DIR__)
  @canary Path.join(@scripts, "canary.sh")

  # More than a pipe buffer, with the needle on the first line.
  @haystack "needle\n" <> String.duplicate(String.duplicate("x", 79) <> "\n", 4096)

  defp canary_contains do
    [function] = Regex.run(~r/^contains\(\) \{\n.*?^\}\n/ms, File.read!(@canary))
    function
  end

  test "the canary finds a needle early in a large body" do
    path = Path.join(System.tmp_dir!(), "sigpipe-#{System.unique_integer([:positive])}")
    File.write!(path, @haystack)
    on_exit(fn -> File.rm(path) end)

    # GitHub's runners ignore SIGPIPE, so printf sees EPIPE rather than dying;
    # trap '' PIPE reproduces that here.
    script = """
    trap '' PIPE
    set -uo pipefail
    ok()  { echo OK; }
    bad() { echo BAD; }
    #{canary_contains()}
    contains "probe" "needle" "$(cat #{path})"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

    assert out =~ "OK",
           "canary.sh's contains() missed a needle on the first line of a 320 KB body:\n#{out}"
  end

  test "no pipefail script pipes a variable into grep -q" do
    offenders =
      for path <- Path.wildcard(Path.join(@scripts, "**/*.sh")),
          source = File.read!(path),
          source =~ "pipefail",
          {line, n} <- Enum.with_index(String.split(source, "\n"), 1),
          line =~ ~r/(echo|printf)\b[^|]*"\$\{?[A-Za-z_]+\}?"\s*\|\s*grep\s+-[a-zA-Z]*q/,
          do: "#{Path.relative_to(path, @scripts)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           These lines read a found match as missing when the variable is larger
           than a pipe buffer. Use `grep -q PATTERN <<<"$VAR"` instead:

             #{Enum.join(offenders, "\n  ")}
           """
  end
end
