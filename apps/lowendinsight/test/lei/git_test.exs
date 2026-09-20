defmodule Lei.GitTest do
  @moduledoc """
  The git wrapper that replaced a seven-year-unmaintained dependency (#250).

  Two things are worth holding here, and neither is about git.

  The first is that a failed command must not look like an empty one.
  `System.cmd/3` returns `{output, status}`, so `{out, _} = System.cmd(...)`
  reads a failure as empty output, and empty output becomes an analysis that
  examined nothing and reported `low`. `run!/2` raises for that reason and is
  the default.

  The second is that stdout carries only output. `git_cli` merged stderr into
  it, which is why `GitModule.git_log_split/2` had to strip `warning:` lines
  before anything could be parsed.
  """
  use ExUnit.Case, async: true

  alias Lei.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "leigit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", "."], cd: dir)
    File.write!(Path.join(dir, "a.txt"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "one"],
        cd: dir
      )

    %{dir: dir, repo: Git.new(dir)}
  end

  describe "a command that succeeds" do
    test "returns its output", %{repo: repo} do
      assert {:ok, out} = Git.run(repo, ["log", "-1", "--pretty=format:%s"])
      assert String.trim(out) == "one"
    end

    test "run!/2 returns the output directly", %{repo: repo} do
      assert Git.run!(repo, ["rev-parse", "HEAD"]) |> String.trim() |> String.length() == 40
    end
  end

  describe "a command that fails" do
    # The whole point. A failure that returns "" is indistinguishable from a
    # repository with nothing in it, and every metric derived from it would be
    # computed over nothing and reported as low risk.
    test "run!/2 raises rather than returning an empty string", %{repo: repo} do
      assert_raise Git.Error, fn ->
        Git.run!(repo, ["rev-parse", "refs/heads/does-not-exist"])
      end
    end

    test "the exception carries the status and the arguments", %{repo: repo} do
      err =
        assert_raise Git.Error, fn ->
          Git.run!(repo, ["rev-parse", "refs/heads/nope"])
        end

      assert err.status > 0
      assert err.args == ["rev-parse", "refs/heads/nope"]
      assert err.message =~ "exited"
    end

    test "run/2 reports the status instead of raising", %{repo: repo} do
      assert {:error, status, _} = Git.run(repo, ["rev-parse", "refs/heads/nope"])
      assert status > 0
    end
  end

  describe "stdout carries only output" do
    test "a log does not contain git's own commentary", %{repo: repo} do
      {:ok, out} = Git.run(repo, ["log", "--name-only", "--pretty=format:%H"])

      refute out =~ "warning:"
      refute out =~ "Cloning"
      assert out =~ "a.txt"
    end
  end

  describe "cloning" do
    test "produces a repository handle that works", %{dir: dir} do
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      assert {:ok, repo} = Git.clone(dir, dest)
      assert repo.path == dest
      assert Git.run!(repo, ["log", "-1", "--pretty=format:%s"]) |> String.trim() == "one"
    end

    test "a source that does not exist is an error, not an empty repository" do
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      assert {:error, status} = Git.clone(missing, dest)
      assert status > 0
    end

    test "clone is quiet, so its progress is not mistaken for output", %{dir: dir} do
      # Clone writes "Cloning into ..." to stderr, naming the destination.
      # --quiet silences it; nothing here should be parsed as a result.
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      {:ok, _} = Git.clone(dir, dest)

      assert {:ok, out} = Git.run(nil, ["clone", "--quiet", "--", dir, dest <> "-2"])
      on_exit(fn -> File.rm_rf!(dest <> "-2") end)
      assert out == ""
    end
  end

  describe "clone keeps git's own words off the console" do
    # Clone is the only command that names the remote, and a failure prints
    # `fatal: repository '<url>' does not exist`. Left on the parent's stream
    # that reaches production logs, where a URL beside a ledger timestamp puts
    # a paying wallet next to what it analysed (#149). git_cli captured stderr
    # and so never leaked it; separating the streams everywhere would have
    # regressed that.
    test "a failed clone's message is captured, not printed" do
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      assert {:error, _status, out} =
               Git.run(nil, ["clone", "--quiet", "--", missing, dest], capture_stderr: true)

      assert out =~ "does not exist",
             "git's failure text was not captured, so it went to the console instead"
    end

    test "without capture, that text is not in the output either -- it went to the console" do
      # The other half of the pair. Together these show the option does
      # something: with it the message is in hand, without it the message is
      # somewhere this process cannot see, which in production is the log.
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      assert {:error, _status, out} =
               Git.run(nil, ["clone", "--quiet", "--", missing, dest], capture_stderr: false)

      refute out =~ "does not exist"
    end

    test "clone/2 asks for capture" do
      # A child process writing to the inherited stderr is not observable from
      # ExUnit, so the call site is asserted directly -- the same approach the
      # monitor wiring tests take. Without this, flipping clone/2 back to an
      # uncaptured run would leak repository URLs into production logs and
      # every other test here would still pass.
      source = File.read!(Path.expand("../../lib/lei/git.ex", __DIR__))

      assert source =~ ~r/\[\"clone\".*\], capture_stderr: true\)/s,
             "clone/2 no longer captures stderr, so git's failure text reaches the console"
    end

    test "and clone/2 does not hand that text back to the caller" do
      dest = Path.join(System.tmp_dir!(), "leiclone-#{System.unique_integer([:positive])}")
      missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dest) end)

      assert {:error, status} = Git.clone(missing, dest)
      assert is_integer(status)
    end
  end

  describe "the environment git runs under" do
    # Not observable from the output, and the symptom of getting it wrong is a
    # hang rather than a failure: without GIT_TERMINAL_PROMPT=0 a clone of a
    # private or renamed repository waits for credentials. Asserted directly
    # because the constant is the thing that would regress.
    test "is non-interactive" do
      env = Map.new(Git.env())

      assert env["GIT_TERMINAL_PROMPT"] == "0",
             "git will prompt for credentials and hang instead of failing"

      assert Map.has_key?(env, "GIT_ASKPASS")
    end

    test "is passed on every invocation, not just one branch" do
      # An earlier version of this ran `git var GIT_EDITOR` and asserted it
      # succeeded, which proved nothing about the environment -- a default
      # editor is not evidence that GIT_TERMINAL_PROMPT arrived -- and failed
      # in CI, where no editor is configured. git does not echo its
      # environment back, so the call site is asserted instead: both branches
      # of the options must carry it, or a repository-scoped command silently
      # runs interactive.
      source = File.read!(Path.expand("../../lib/lei/git.ex", __DIR__))

      occurrences =
        source
        |> String.split("env: @env")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 2,
             "expected both cmd_opts branches to pass env: @env, found #{occurrences}"
    end
  end
end
