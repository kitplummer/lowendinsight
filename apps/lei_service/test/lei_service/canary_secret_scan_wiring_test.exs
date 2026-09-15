defmodule LeiService.CanarySecretScanWiringTest do
  @moduledoc """
  The canary scans what it fetched for secrets, and an empty fetch fails.

  The scanner is tested in SecretScanScriptTest. This pins how scripts/canary.sh
  uses it: which bodies it scans, and that a body it could not fetch is a
  failure rather than a clean page. A canary that stopped scanning, or scanned
  nothing, would otherwise report exactly what a clean deployment reports.
  """
  use ExUnit.Case, async: true

  @canary File.read!(Path.expand("../../../../scripts/canary.sh", __DIR__))

  test "every body the canary fetches for its other checks is scanned" do
    for {label, var} <- [
          {"home page", "HOME_BODY"},
          {"llms.txt", "LLMS_BODY"},
          {"Try It report", "REPORT"},
          {"trending (elixir)", "TRENDING"},
          {"readyz", "READYZ"}
        ] do
      assert @canary =~ ~r/scan_body "#{Regex.escape(label)}" "\$\{?#{var}/,
             "canary.sh does not scan #{var}"
    end
  end

  test "the scanner's findings fail the canary" do
    assert @canary =~ ~r/1\) bad "no secrets: \$\{label\}" "\$out" ;;/
  end

  test "a body with nothing to scan fails the canary rather than passing it" do
    assert @canary =~ ~r/\*\) bad "no secrets: \$\{label\}" "nothing to scan/
  end
end
