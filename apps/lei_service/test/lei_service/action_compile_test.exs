defmodule LeiService.ActionCompileTest do
  @moduledoc """
  The action's build fails, with its cause on record, rather than hanging.

  On #353's lei-sarif run the action's `mix compile` printed "Waiting for lock
  on the build directory (held by process 2498)" and waited until the job's
  30-minute timeout cancelled it (#354). The same cold build passed on the
  next attempt and on 36 deliberate cold builds, so the cause is not known. A
  user's workflow has no 30-minute limit unless they set one; GitHub's default
  is six hours.

  `scripts/action-compile.sh` bounds the compile. On the limit it prints the
  process tree and the lock holder -- the evidence #354 is missing -- kills
  what it started and fails. It does not retry: a retry would turn an
  unexplained deadlock into a slower pass, and the next occurrence would leave
  nothing behind.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/action-compile.sh")

  setup do
    dir = Path.join(System.tmp_dir!(), "action-compile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    marker = "lei-fake-mix-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      System.cmd("pkill", ["-KILL", "-f", marker], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    %{dir: dir, marker: marker}
  end

  # `mix` replaced on PATH by `body`.
  defp stub_mix(dir, body) do
    File.write!(Path.join(dir, "bin/mix"), "#!/usr/bin/env bash\n" <> body)
    File.chmod!(Path.join(dir, "bin/mix"), 0o755)
  end

  # Bounded here too: a script that never returns must fail this test, not
  # hang the suite.
  defp run(dir, limit) do
    task =
      Task.async(fn ->
        System.cmd("bash", [@script],
          env: [
            {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
            {"LEI_COMPILE_TIMEOUT", to_string(limit)}
          ],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("action-compile.sh did not return: the limit did not stop the compile")
    end
  end

  defp running?(marker) do
    {_, code} = System.cmd("pgrep", ["-f", marker])
    code == 0
  end

  test "a compile that finishes passes, with its output", %{dir: dir} do
    stub_mix(dir, ~s(echo "Generated lowendinsight app"\n))

    {out, code} = run(dir, 10)

    assert code == 0
    assert out =~ "Generated lowendinsight app"
  end

  test "a compile that fails fails the step", %{dir: dir} do
    stub_mix(dir, ~s(echo "== Compilation error"\nexit 3\n))

    {out, code} = run(dir, 10)

    assert code != 0
    assert out =~ "== Compilation error"
  end

  test "a hung compile fails with the lock holder on record", %{dir: dir, marker: marker} do
    stub_mix(dir, """
    echo "Waiting for lock on the build directory (held by process $$)" >&2
    exec -a #{marker} sleep 600
    """)

    {out, code} = run(dir, 2)

    assert code != 0
    assert out =~ "::error::mix compile did not finish in 2s"
    assert out =~ "issues/354"
    assert out =~ "lock holder"
    assert out =~ marker, "the compile's processes were not printed"
    refute running?(marker), "the hung compile was left running"
  end

  # The output goes into a workflow log that may be public. Another process
  # on the runner can carry a token in its arguments.
  test "a hang prints only the compile's processes, not the machine's", %{
    dir: dir,
    marker: marker
  } do
    bystander = "#{marker}-bystander-token"
    System.cmd("bash", ["-c", "(exec -a #{bystander} sleep 60) >/dev/null 2>&1 &"])

    stub_mix(dir, "exec -a #{marker} sleep 600\n")
    {out, _code} = run(dir, 1)

    refute out =~ bystander, "an unrelated process's arguments were printed"
  end

  test "the action compiles through the bound" do
    action = File.read!(Path.join(@root, "action.yml"))

    assert action =~ ~s("$GITHUB_ACTION_PATH/scripts/action-compile.sh")
    refute action =~ ~r/^\s+mix compile\s*$/m, "the action still runs an unbounded mix compile"
  end
end
