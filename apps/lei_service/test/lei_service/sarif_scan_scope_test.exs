defmodule LeiService.SarifScanScopeTest do
  @moduledoc """
  This repository's SARIF scan is bounded, and scans what we ship.

  On 2026-10-27 the scan took between one and two hours instead of about
  eleven minutes, and six runs were in progress at once. The VS Code
  extension's package-lock.json had become tracked (#331): 341 repositories to
  clone, every one a dev-only build tool of an extension with no runtime
  dependencies. The workflow had no timeout and nothing cancelled a run a newer
  commit had replaced, so each push added another.

  The workflow cannot be run from a test, so its artefacts are asserted.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/lei_sarif.yml")
  @action Path.join(@root, "action.yml")
  @extension "apps/lei_service/vscode-lowendinsight"

  test "the extension's build tooling is excluded from the scan" do
    workflow = File.read!(@workflow)

    assert workflow =~ ~r/exclude:\s*#{Regex.escape(@extension)}/,
           "the scan analyses the editor extension's dev-only lockfile again"

    # An exclusion naming a directory that moved would be refused by the scan;
    # this says so before CI does.
    assert File.dir?(Path.join(@root, @extension))
  end

  test "a scan that hangs fails, rather than holding a runner for hours" do
    assert [_, minutes] = Regex.run(~r/timeout-minutes:\s*(\d+)/, File.read!(@workflow))
    assert String.to_integer(minutes) <= 60
  end

  test "a newer commit on a pull request replaces the run for the older one" do
    workflow = File.read!(@workflow)

    assert workflow =~ "concurrency:"
    assert workflow =~ "cancel-in-progress:"
  end

  test "the action takes exclude, through the environment" do
    action = File.read!(@action)

    assert action =~ ~r/^  exclude:/m, "action.yml declares no exclude input"
    assert action =~ "IN_EXCLUDE: ${{ inputs.exclude }}"
    assert action =~ "--exclude", "the input is never passed to the scan"

    [_, scan_step] = String.split(action, "    - name: Scan\n", parts: 2)
    [_env, script] = String.split(scan_step, "      run: |\n", parts: 2)

    refute script =~ "${{ inputs.",
           "an input interpolated into the script is a script injection"
  end

  test "JSON mode refuses exclude rather than ignoring it" do
    # mix lei.scan has no --exclude; silently scanning everything would be the
    # opposite of what was asked.
    assert File.read!(@action) =~ "exclude is supported in SARIF mode only"
  end
end
