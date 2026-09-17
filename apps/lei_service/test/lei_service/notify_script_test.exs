defmodule LeiService.NotifyScriptTest do
  @moduledoc """
  `scripts/notify.sh` is how an operations alert reaches the operator (ntfy).

  An alert that cannot be sent must fail the step that sends it: a notifier
  that exits 0 with no token configured reports exactly what a delivered alert
  reports. And the token must never be on a command line, where it would land
  in the process list or a CI log.

  `curl` is replaced on PATH by a stub that records its arguments and its
  stdin separately, and answers with a chosen HTTP status.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/notify.sh", __DIR__)
  @token "tk_test_token_value_should_stay_off_argv"

  setup do
    dir = Path.join(System.tmp_dir!(), "notify-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))

    File.write!(Path.join(dir, "bin/curl"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$@" > "#{dir}/argv"
    cat > "#{dir}/stdin"
    printf '%s' "$(cat "#{dir}/status" 2>/dev/null || echo 200)"
    """)

    File.chmod!(Path.join(dir, "bin/curl"), 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run(dir, args, env) do
    System.cmd("bash", [@script | args],
      env: [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")} | env],
      stderr_to_stdout: true
    )
  end

  defp configured, do: [{"NTFY_TOKEN", @token}, {"NTFY_TOPIC", "lei-ops-test"}]

  test "the script exists and is executable" do
    assert File.stat!(@script).mode |> Bitwise.band(0o111) != 0
  end

  test "sends the title, priority, tags and link as headers, and the token only on stdin", %{
    dir: dir
  } do
    {out, code} =
      run(
        dir,
        [
          "--title",
          "LEI: readyz degraded",
          "--priority",
          "5",
          "--tags",
          "rotating_light",
          "--click",
          "https://example.test/run/1",
          "queue backed up"
        ],
        configured()
      )

    assert code == 0, out
    headers = File.read!(Path.join(dir, "stdin"))
    argv = File.read!(Path.join(dir, "argv"))

    assert headers =~ "Authorization: Bearer #{@token}"
    assert headers =~ "Title: LEI: readyz degraded"
    assert headers =~ "Priority: 5"
    assert headers =~ "Tags: rotating_light"
    assert headers =~ "Click: https://example.test/run/1"

    refute argv =~ @token
    assert argv =~ "https://ntfy.sh/lei-ops-test"
    assert argv =~ "queue backed up"
    refute out =~ @token
  end

  test "without a token or topic it fails, rather than exiting 0 having sent nothing", %{dir: dir} do
    for env <- [[{"NTFY_TOPIC", "lei-ops-test"}], [{"NTFY_TOKEN", @token}], []] do
      {out, code} = run(dir, ["--title", "t", "m"], env)
      assert code == 2, "expected failure for #{inspect(Enum.map(env, &elem(&1, 0)))}: #{out}"
      assert out =~ "would go nowhere"
    end

    refute File.exists?(Path.join(dir, "argv"))
  end

  test "a notification ntfy does not accept fails the step", %{dir: dir} do
    File.write!(Path.join(dir, "status"), "403")

    {out, code} = run(dir, ["--title", "t", "m"], configured())

    assert code == 1
    assert out =~ "HTTP 403"
    refute out =~ @token
  end

  test "bad usage is refused before anything is sent", %{dir: dir} do
    for args <- [
          ["m"],
          ["--title", "t"],
          ["--title", "t", "--priority", "9", "m"],
          ["--bogus", "m"]
        ] do
      {_out, code} = run(dir, args, configured())
      assert code == 2, "expected usage failure for #{inspect(args)}"
    end

    {_out, code} =
      run(dir, ["--title", "t", "m"], [{"NTFY_TOKEN", @token}, {"NTFY_TOPIC", "bad topic/../x"}])

    assert code == 2

    refute File.exists?(Path.join(dir, "argv"))
  end
end
