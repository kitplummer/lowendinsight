defmodule LeiService.DepsFetchRetryTest do
  @moduledoc """
  A registry error does not fail CI; a defect still does.

  hex.pm returned 500 to one `mix deps.get` in umbrella_ci on main
  (2026-10-24). The run failed, deploy declined the commit, and monitor reported
  an undeployed tip every fifteen minutes for seven hours. Every workflow now
  fetches through `scripts/mix-deps-get.sh`, which retries the fetch -- and only
  the fetch. A fetch that fails every time still fails.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/mix-deps-get.sh")

  setup do
    dir = Path.join(System.tmp_dir!(), "depsget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # `mix` replaced on PATH: fails the first `failures` calls, then succeeds.
  defp stub_mix(dir, failures) do
    File.write!(Path.join(dir, "bin/mix"), """
    #!/usr/bin/env bash
    n=$(( $(cat "#{dir}/calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "#{dir}/calls"
    echo "mix $*"
    [ "$n" -gt #{failures} ]
    """)

    File.chmod!(Path.join(dir, "bin/mix"), 0o755)
  end

  defp run(dir) do
    {out, code} =
      System.cmd("bash", [@script, "--only", "test"],
        env: [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"LEI_DEPS_RETRY_DELAY", "0"}
        ],
        stderr_to_stdout: true
      )

    {out, code, String.trim(File.read!(Path.join(dir, "calls")))}
  end

  test "a transient failure is retried, visibly, and the fetch succeeds", %{dir: dir} do
    stub_mix(dir, 2)
    {out, code, calls} = run(dir)

    assert code == 0
    assert calls == "3"
    assert out =~ "::warning::mix deps.get failed (attempt 1 of 3)"
    assert out =~ "mix deps.get --only test", "arguments were not passed through"
  end

  test "a fetch that always fails still fails the job", %{dir: dir} do
    stub_mix(dir, 99)
    {out, code, calls} = run(dir)

    assert code == 1
    assert calls == "3"
    assert out =~ "::error::mix deps.get failed 3 times"
  end

  test "success is not retried", %{dir: dir} do
    stub_mix(dir, 0)
    {_out, 0, calls} = run(dir)
    assert calls == "1"
  end

  test "no workflow or CI script fetches dependencies without the retry" do
    files =
      [
        Path.join(@root, "action.yml")
        | Path.wildcard(Path.join(@root, ".github/workflows/*.yml"))
      ] ++
        (Path.wildcard(Path.join(@root, "scripts/**/*.sh")) --
           [Path.join(@root, "scripts/mix-deps-get.sh")])

    bare =
      for path <- files,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          line =~ ~r/(^|[\s;&|])mix deps\.get\b/,
          not String.starts_with?(String.trim_leading(line), "#"),
          do: "#{Path.relative_to(path, @root)}:#{n}: #{String.trim(line)}"

    assert bare == [],
           "these fetch without retry; use scripts/mix-deps-get.sh:\n  #{Enum.join(bare, "\n  ")}"
  end
end
