defmodule LeiService.RunDeployedTest do
  @moduledoc """
  The monitor runs the smoke test that belongs to the release it is testing.

  The monitor checks out main and probes production every 15 minutes. Between
  a merge and its deploy, main's smoke test describes a release that is not
  running yet, so a change to what the smoke test expects -- the MCP change
  that made `tools/list` answer without a key, for one -- fails the monitor
  for the length of every deploy, against a production that is fine.

  `scripts/ops/run-deployed.sh` asks production which commit it is running
  and runs that commit's copy of the script. When it cannot tell, it fails:
  running main's copy instead would bring the false failures back, and
  passing would be a check that passes when it cannot do its job.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @run_deployed Path.join(@root, "scripts/ops/run-deployed.sh")
  @monitor Path.join(@root, ".github/workflows/monitor.yml")

  setup do
    dir = Path.join(System.tmp_dir!(), "run-deployed-#{System.unique_integer([:positive])}")
    repo = Path.join(dir, "repo")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "t@example.test"])
    git(repo, ["config", "user.name", "t"])

    deployed = commit(repo, ~s(echo "probe from the deployed release: $*"\nexit "${PROBE_EXIT:-0}"))
    main = commit(repo, ~s(echo "probe from main"\nexit 0))

    %{dir: dir, repo: repo, bin: bin, deployed: deployed, main: main}
  end

  defp git(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(repo, probe) do
    path = Path.join(repo, "scripts/probe.sh")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/usr/bin/env bash\n" <> probe <> "\n")
    File.chmod!(path, 0o755)
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "-m", "probe"])
    git(repo, ["rev-parse", "HEAD"])
  end

  # A curl on PATH that answers /metrics with `body`.
  defp serve_metrics(bin, body) do
    File.write!(Path.join(bin, "metrics.body"), body)

    File.write!(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    cat "#{bin}/metrics.body"
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
  end

  defp build_info(sha), do: ~s(lei_build_info{sha="#{sha}",lei_version="0.16.0"} 1\n)

  defp run(%{repo: repo, bin: bin}, args, env \\ []) do
    System.cmd("bash", [@run_deployed, "https://example.test" | args],
      cd: repo,
      env: [{"PATH", "#{bin}:#{System.get_env("PATH")}"} | env],
      stderr_to_stdout: true
    )
  end

  test "runs the deployed commit's copy of the script, not main's", ctx do
    serve_metrics(ctx.bin, build_info(ctx.deployed))

    assert {out, 0} = run(ctx, ["scripts/probe.sh", "https://example.test"])
    assert out =~ "probe from the deployed release: https://example.test"
    refute out =~ "probe from main"
    assert out =~ String.slice(ctx.deployed, 0, 7)
  end

  test "the script's failure is the run's failure", ctx do
    serve_metrics(ctx.bin, build_info(ctx.deployed))

    assert {_out, code} = run(ctx, ["scripts/probe.sh"], [{"PROBE_EXIT", "3"}])
    assert code == 3
  end

  test "a build that publishes no lei_build_info fails, and runs nothing", ctx do
    serve_metrics(ctx.bin, "lei_queue_available 0\n")

    assert {out, code} = run(ctx, ["scripts/probe.sh"])
    assert code != 0
    assert out =~ "::error::"
    refute out =~ "probe from"
  end

  test "a build that cannot name its commit fails, and runs nothing", ctx do
    serve_metrics(ctx.bin, build_info("unknown"))

    assert {out, code} = run(ctx, ["scripts/probe.sh"])
    assert code != 0
    assert out =~ "::error::"
    refute out =~ "probe from"
  end

  test "a commit that is not in the repository fails, and runs nothing", ctx do
    serve_metrics(ctx.bin, build_info(String.duplicate("e", 40)))

    assert {out, code} = run(ctx, ["scripts/probe.sh"])
    assert code != 0
    assert out =~ "::error::"
    refute out =~ "probe from"
  end

  test "an unreadable /metrics fails, and runs nothing", ctx do
    serve_metrics(ctx.bin, "<html>502</html>\n")

    assert {out, code} = run(ctx, ["scripts/probe.sh"])
    assert code != 0
    refute out =~ "probe from"
  end

  test "a deployed commit missing from a shallow checkout is fetched", ctx do
    # actions/checkout fetches one commit: the tip of main. The deployed one
    # is behind it during every deploy.
    shallow = Path.join(ctx.dir, "shallow")

    git(ctx.dir, ["clone", "-q", "--depth=1", "file://#{ctx.repo}", shallow])
    assert {_, code} = System.cmd("git", ["cat-file", "-e", ctx.deployed <> "^{commit}"], cd: shallow, stderr_to_stdout: true)
    assert code != 0, "the shallow clone already has the deployed commit; this tests nothing"

    serve_metrics(ctx.bin, build_info(ctx.deployed))

    assert {out, 0} = run(%{ctx | repo: shallow}, ["scripts/probe.sh"])
    assert out =~ "probe from the deployed release"
  end

  test "the monitor runs the deployed smoke test" do
    monitor = File.read!(@monitor)

    assert monitor =~
             "scripts/ops/confirm.sh smoke scripts/ops/run-deployed.sh https://lowendinsight.dev scripts/smoke-test.sh https://lowendinsight.dev"
  end
end
