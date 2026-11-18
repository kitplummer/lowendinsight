defmodule LeiService.ProbeUserAgentTest do
  @moduledoc """
  Our own probes are counted as ours, not as adoption.

  `Lei.Adoption` buckets analysis calls by user agent to answer whether anyone
  uses the service. `smoke-test.sh` and `canary.sh` run in the monitor every 15
  minutes and on every deploy, and both called the analysis with curl's own
  user agent, which buckets as `script`. On 2026-11-17 the 30-day counts read
  12,182 `script` against 8 `browser`, and the probes account for nearly all of
  it: roughly four analysis calls a run, 96 runs a day. The number meant to say
  whether anyone uses this said mostly that the monitor does.

  The probes now name themselves `lowendinsight-monitor/1`, which buckets as
  `internal`. These run each script against a `curl` stub and require every
  call it makes to carry that user agent, so a new curl added without it fails
  here rather than quietly inflating the count again.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "probe-ua-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Records each call's arguments, NUL-separated, one call per line; answers
    # nothing, so each script runs until its own checks give up.
    File.write!(Path.join(dir, "curl"), """
    #!/usr/bin/env bash
    printf '%s\\0' "$@" >> "#{dir}/calls"
    printf '\\n' >> "#{dir}/calls"
    exit 0
    """)

    File.chmod!(Path.join(dir, "curl"), 0o755)
    %{dir: dir}
  end

  defp calls(dir, script) do
    System.cmd("bash", [Path.join(@root, script), "http://stub.test"],
      env: [
        {"PATH", "#{dir}:#{System.get_env("PATH")}"},
        {"LEI_SMOKE_API_KEY", "lei_test"}
      ],
      stderr_to_stdout: true
    )

    Path.join(dir, "calls")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, <<0>>, trim: true))
  end

  defp user_agent(args) do
    case Enum.drop_while(args, &(&1 not in ["-A", "--user-agent"])) do
      [_, ua | _] -> ua
      _ -> nil
    end
  end

  for script <- ["scripts/smoke-test.sh", "scripts/canary.sh"] do
    test "every request #{script} makes names itself", %{dir: dir} do
      calls = calls(dir, unquote(script))

      assert Enum.any?(calls, fn args -> Enum.any?(args, &(&1 =~ ~r{/v1/analyze|/url=})) end),
             "the stub never saw an analysis call, so this proves nothing"

      for args <- calls do
        ua = user_agent(args)

        assert ua && Lei.Adoption.bucket(ua) == "internal",
               "a request is counted as adoption (#{inspect(Lei.Adoption.bucket(ua))}): " <>
                 inspect(args)
      end
    end
  end
end
