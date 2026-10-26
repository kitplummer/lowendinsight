defmodule LeiService.DependencyAuditRegistryTest do
  @moduledoc """
  A registry that does not answer is not an advisory.

  `mix hex.audit` exits non-zero both when a locked package has an advisory
  and when Hex could not fetch a package's registry entry. Preflight failed on
  2026-10-25 on `parse_trans 3.4.2: the registry entry could not be fetched`
  (`:timeout`), and the daily audit runs the same script: one slow response
  from hex.pm would be a failure email that means nothing about the
  dependencies.

  An unfetched entry is retried. A finding is not. An entry still unfetched
  after the retries fails, because the audit could not do its job.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/dependency-audit.sh")

  setup do
    dir = Path.join(System.tmp_dir!(), "hexaudit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A mix whose `hex.audit` gives `responses` in turn, then repeats the last.
  defp stub_mix(dir, responses) do
    for {{out, code}, i} <- Enum.with_index(responses, 1) do
      File.write!(Path.join(dir, "audit.#{i}"), out)
      File.write!(Path.join(dir, "audit.#{i}.code"), "#{code}")
    end

    File.write!(Path.join(dir, "mix"), """
    #!/usr/bin/env bash
    case "$1" in
      hex.audit)
        n=$(( $(cat "#{dir}/calls" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "#{dir}/calls"
        i=$n; [ -f "#{dir}/audit.$i" ] || i=#{length(responses)}
        cat "#{dir}/audit.$i"; exit $(cat "#{dir}/audit.$i.code") ;;
      hex.info) echo "Hex: 2.5.1" ;;
      deps.audit) echo "No vulnerabilities found." ;;
    esac
    """)

    File.chmod!(Path.join(dir, "mix"), 0o755)
  end

  defp audit(dir) do
    {out, code} =
      System.cmd("bash", [@script],
        env: [{"PATH", "#{dir}:#{System.get_env("PATH")}"}, {"LEI_AUDIT_RETRY_DELAY", "0"}],
        stderr_to_stdout: true
      )

    {out, code, String.trim(File.read!(Path.join(dir, "calls")))}
  end

  @unfetched {"Failed to fetch record for parse_trans from registry (using cache instead)\n:timeout\n** (Mix) Could not audit these locked packages:\n  parse_trans 3.4.2: the registry entry could not be fetched\n",
              1}
  @clean {"No retired or vulnerable packages found\n", 0}
  @finding {"Dependency       Version  Advisory\nplug_crypto      2.1.0    GHSA-xxxx (HIGH)\n", 1}

  test "an entry that could not be fetched is fetched again", %{dir: dir} do
    stub_mix(dir, [@unfetched, @clean])
    {out, code, calls} = audit(dir)

    assert code == 0, out
    assert calls == "2"
    assert out =~ "::warning::"
  end

  test "an entry that never arrives fails: the audit did not happen", %{dir: dir} do
    stub_mix(dir, [@unfetched])
    {out, code, calls} = audit(dir)

    assert code != 0
    assert calls == "3"
    assert out =~ "could not be fetched"
  end

  test "an advisory is not retried", %{dir: dir} do
    stub_mix(dir, [@finding])
    {out, code, calls} = audit(dir)

    assert code != 0
    assert calls == "1"
    assert out =~ "unacknowledged advisories"
  end
end
