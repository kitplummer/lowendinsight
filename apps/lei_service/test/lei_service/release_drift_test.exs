defmodule LeiService.ReleaseDriftTest do
  @moduledoc """
  The daily audit fails on release drift only when a release has actually gone
  wrong, never while one is going right.

  A failed run emails, and an email has to mean something is unhealthy. The
  guard in audit.yml went red in three situations where nothing was:

    * hex.pm could not be read. It passed instead -- "could not tell" counted
      as agreement -- which is the other way to be wrong.
    * the CHANGELOG dated a version that was not yet tagged: every release, for
      however long it took between merging that PR and pushing the tag.
    * a library change merged after a release, before anyone bumped the
      version. The PR that did it got a warning; main got the red run, daily.

  Now: hex is retried and a failure to read it fails; a dated, untagged
  version warns until it has been dated for 72 hours; and the PR that moves
  the library past a published version fails, so main never does.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @script Path.join(@root, "scripts/ops/release-drift.sh")
  @audit Path.join(@root, ".github/workflows/audit.yml")

  setup do
    dir = Path.join(System.tmp_dir!(), "drift-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(repo, "apps/lowendinsight"))

    File.write!(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    [ -f "#{dir}/hex.json" ] || exit 22
    cat "#{dir}/hex.json"
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.test"])
    git!(repo, ["config", "user.name", "t"])
    %{dir: dir, bin: bin, repo: repo}
  end

  defp git!(repo, args, env \\ []) do
    {_, 0} = System.cmd("git", args, cd: repo, env: env, stderr_to_stdout: true)
  end

  defp commit!(repo, version, heading, opts \\ []) do
    File.write!(Path.join(repo, "apps/lowendinsight/mix.exs"), ~s(  version: "#{version}",\n))
    File.write!(Path.join(repo, "apps/lowendinsight/CHANGELOG.md"), "# Changelog\n\n#{heading}\n")

    if extra = opts[:touch],
      do:
        File.write!(Path.join(repo, "apps/lowendinsight/#{extra}"), "#{System.unique_integer()}")

    git!(repo, ["add", "-A"])
    date = "@#{System.os_time(:second) - (opts[:days_ago] || 0) * 86_400} +0000"
    git!(repo, ["commit", "-qm", "c"], [{"GIT_COMMITTER_DATE", date}, {"GIT_AUTHOR_DATE", date}])
  end

  defp published!(dir, versions) do
    releases = Enum.map(versions, &%{"version" => &1})
    File.write!(Path.join(dir, "hex.json"), Jason.encode!(%{"releases" => releases}))
  end

  defp drift(ctx, event, base \\ "main") do
    System.cmd("bash", [@script],
      cd: ctx.repo,
      env: [
        {"PATH", "#{ctx.bin}:#{System.get_env("PATH")}"},
        {"GITHUB_EVENT_NAME", event},
        {"LEI_DRIFT_BASE", base}
      ],
      stderr_to_stdout: true
    )
  end

  describe "when hex cannot be read" do
    test "the daily run fails rather than concluding agreement", ctx do
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01")
      {out, code} = drift(ctx, "schedule")

      assert code != 0
      assert out =~ "::error::"
    end

    test "a pull request is not failed by hex being down", ctx do
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01")
      {out, 0} = drift(ctx, "pull_request")
      assert out =~ "::warning::"
    end
  end

  describe "a dated version hex does not have" do
    test "warns while the release is in progress", ctx do
      published!(ctx.dir, ["0.9.0"])
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01")

      {out, 0} = drift(ctx, "schedule")
      assert out =~ "::warning::"
      assert out =~ "v1.0.0"
    end

    test "fails once it has been dated for more than 72 hours", ctx do
      published!(ctx.dir, ["0.9.0"])
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01", days_ago: 4)

      {out, code} = drift(ctx, "schedule")
      assert code != 0
      assert out =~ "::error::"
      assert out =~ "v1.0.0"
    end
  end

  describe "library changes after a published version" do
    setup ctx do
      published!(ctx.dir, ["1.0.0"])
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01")
      git!(ctx.repo, ["tag", "v1.0.0"])
      git!(ctx.repo, ["checkout", "-qb", "pr"])
      :ok
    end

    test "fail the pull request that makes them", ctx do
      commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01", touch: "lib.ex")

      {out, code} = drift(ctx, "pull_request")
      assert code != 0
      assert out =~ "::error::"
      assert out =~ "Bump the version"
    end

    test "do not fail a pull request that touches nothing in the library", ctx do
      File.write!(Path.join(ctx.repo, "README.md"), "x")
      git!(ctx.repo, ["add", "-A"])
      git!(ctx.repo, ["commit", "-qm", "docs"])

      {out, 0} = drift(ctx, "pull_request")
      refute out =~ "::error::"
    end

    test "pass once the pull request bumps the version", ctx do
      commit!(ctx.repo, "1.0.1-beta.1", "## 1.0.1-beta.1 — Unreleased", touch: "lib.ex")
      {out, 0} = drift(ctx, "pull_request")
      refute out =~ "::error::"
    end
  end

  test "agreement passes quietly", ctx do
    published!(ctx.dir, ["1.0.0"])
    commit!(ctx.repo, "1.0.0", "## 1.0.0 — 2026-01-01")
    git!(ctx.repo, ["tag", "v1.0.0"])

    {out, 0} = drift(ctx, "schedule")
    refute out =~ "::error::"
    refute out =~ "::warning::"
  end

  test "audit.yml runs this script" do
    assert File.read!(@audit) =~ "scripts/ops/release-drift.sh"
  end
end
