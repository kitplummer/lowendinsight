defmodule LeiService.AlertChannelTest do
  use ExUnit.Case, async: true

  # `scripts/check-alert-channel.sh` is a script and these drive it, because the
  # whole change is a behavioural distinction -- retry a transport failure, do
  # not retry a credential rejection -- that no assertion about the contents of
  # monitor.yml could catch.
  #
  # `curl` is stubbed on PATH rather than a server being spawned. Two earlier
  # versions spawned a python HTTP server: the first slept 700ms and raced its
  # startup, the second outlived `Port.close` and hung the test run. Both failed
  # by returning HTTP 000, which reads exactly like the script failing to reach
  # a live channel -- a test harness reporting the wrong thing confidently.
  #
  # The stub answers with a sequence of statuses, one per call, which is all
  # these cases need.
  @script Path.expand("../../../../scripts/check-alert-channel.sh", __DIR__)

  defp with_curl(statuses, fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "curlstub-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    counter = Path.join(dir, "n")
    File.write!(counter, "0")

    # Prints the nth status and advances. Ignores every argument, because what
    # is under test is how the script reacts to a status, not how it builds a
    # request.
    File.write!(Path.join(dir, "curl"), """
    #!/usr/bin/env bash
    n=$(cat #{counter})
    echo $((n + 1)) > #{counter}
    seq=(#{Enum.join(statuses, " ")})
    i=$n
    if [ "$i" -ge "${#seq[@]}" ]; then i=$(( ${#seq[@]} - 1 )); fi
    printf '%s' "${seq[$i]}"
    """)

    File.chmod!(Path.join(dir, "curl"), 0o755)
    fun.(dir)
  end

  defp probe(statuses, env \\ []) do
    with_curl(statuses, fn dir ->
      base = [
        {"PATH", dir <> ":" <> System.get_env("PATH")},
        {"NTFY_TOPIC", "t"},
        {"NTFY_SERVER", "https://ntfy.example"},
        {"ALERT_PROBE_ATTEMPTS", "3"},
        {"ALERT_PROBE_GAP", "0"}
      ]

      System.cmd("bash", ["-c", "printf 'tok\\n' | #{@script}"],
        env: base ++ env,
        stderr_to_stdout: true
      )
    end)
  end

  test "a reachable channel passes on the first probe" do
    {out, status} = probe(["200"])

    assert status == 0, out
    assert out =~ "probe 1/3"
    refute out =~ "probe 2/3", "a healthy channel was probed more than once"
  end

  test "a blip recovers rather than paging" do
    # The incident this fixes: the monitor's probe returned HTTP 000 at 04:24 on
    # 2026-10-05 and the next fifteen runs all succeeded. One unreachable probe
    # is weather, and it woke a human about our own monitoring.
    {out, status} = probe(["000", "200"])

    assert status == 0, out
    assert out =~ "probe 2/3"
    assert out =~ "accepts this token"
  end

  test "a rejected credential fails on the first probe, without retrying" do
    # Deterministic: the token will still be wrong in twenty seconds, and the
    # only thing that matters is telling someone promptly. Retrying would delay
    # the page it needs to send.
    for code <- ["401", "403"] do
      {out, status} = probe([code])

      assert status == 1
      assert out =~ "rejected the paging credential"

      refute out =~ "probe 2/3",
             "HTTP #{code} was retried, which delays the page rather than sending it"
    end
  end

  test "a channel down for every attempt fails" do
    {out, status} = probe(["000", "000", "000"])

    assert status == 1
    assert out =~ "probe 3/3"
    assert out =~ "Could not reach ntfy in 3 attempts"
  end

  test "a server error that never clears fails" do
    {out, status} = probe(["503"])

    assert status == 1
    assert out =~ "Could not reach ntfy in 3 attempts"
  end

  test "an absent token or topic fails immediately" do
    {out, status} =
      System.cmd("bash", ["-c", "printf '' | #{@script}"],
        env: [{"NTFY_TOPIC", "t"}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert out =~ "so no check in this file can page anyone"

    {out2, status2} = probe(["200"], [{"NTFY_TOPIC", ""}])
    assert status2 == 1
    assert out2 =~ "so no check in this file can page anyone"
  end

  test "the monitor invokes the script and passes the token on stdin" do
    monitor = File.read!(Path.expand("../../../../.github/workflows/monitor.yml", __DIR__))

    assert monitor =~ "scripts/check-alert-channel.sh",
           "the alert channel check is not wired into the monitor"

    assert monitor =~ "\"$NTFY_TOKEN\" | scripts/check-alert-channel.sh",
           "the token must reach the script on stdin, never as an argument"
  end
end
