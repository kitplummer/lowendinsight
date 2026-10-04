defmodule LeiService.BuildShaTest do
  use ExUnit.Case, async: true

  describe "the gauge" do
    test "publishes exactly what build_sha/0 reports" do
      # The invariant, and it holds whether or not the build arg was passed:
      # the gauge states the compiled-in value rather than anything read at
      # scrape time.
      #
      # The first version of this test asserted `metrics =~ "lei_version=\""`
      # as an alternative, which almost nothing could fail -- the exact weakness
      # this file is otherwise written against.
      metrics = Lei.Metrics.collect()
      version = to_string(Application.spec(:lowendinsight, :vsn))

      assert metrics =~
               "lei_build_info{sha=\"#{Lei.Metrics.build_sha()}\",lei_version=\"#{version}\"} 1"
    end

    test "the gauge is published even when the commit is unknown" do
      # A local or CI build passes no arg. The gauge must still appear: a
      # reader that cannot find lei_build_info cannot tell "old build" from
      # "scrape failed", which is why the check treats an absent gauge and an
      # unknown sha identically.
      assert Lei.Metrics.collect() =~ "lei_build_info{sha="
    end

    test "build_sha/0 is never blank" do
      # An empty string would render as sha="" and read as a build that
      # answered rather than one that could not be identified.
      sha = Lei.Metrics.build_sha()

      assert is_binary(sha) and sha != ""
      assert sha == "unknown" or String.match?(sha, ~r/^[0-9a-f]{7,40}$/)
    end
  end

  describe "the check, run rather than read" do
    # `scripts/check-deployed-sha.sh` is a script and not inline YAML for the
    # same reason as the cache-headroom check: a test that asserts strings are
    # present in a workflow cannot catch a change to the shell logic, and two
    # mutations against inline logic came back unguarded when that was tried.
    @script Path.expand("../../../../scripts/check-deployed-sha.sh", __DIR__)

    defp check(metrics, expected) do
      path =
        Path.join(System.tmp_dir!(), "sha-#{System.pid()}-#{System.unique_integer([:positive])}")

      File.write!(path, metrics)
      on_exit(fn -> File.rm_rf(path) end)

      {out, status} =
        System.cmd("bash", ["-c", "#{@script} #{expected} < #{path}"], stderr_to_stdout: true)

      {status, out}
    end

    @running "lei_build_info{sha=\"abc1234\",lei_version=\"0.13.1\"} 1\n"

    test "the expected commit passes" do
      assert {0, out} = check(@running, "abc1234")
      assert out =~ "the tip of main"
    end

    test "a different commit fails, and says the service is the one to believe" do
      # The case GitHub cannot see: a deploy that reported success while
      # shipping something else, or a machine that rolled back quietly.
      assert {1, out} = check(@running, "deadbeef")
      assert out =~ "but the tip of main is"
      assert out =~ "the service is the one to believe"
    end

    test "an unidentifiable build fails rather than passing" do
      unknown = String.replace(@running, "abc1234", "unknown")

      assert {1, out} = check(unknown, "abc1234")
      assert out =~ "cannot verify"
    end

    test "an absent gauge fails rather than being skipped" do
      # An old release publishes no such gauge, and that is exactly the build
      # whose identity cannot be confirmed. Absence must not read as health.
      assert {1, out} = check("beam_memory_bytes{type=\"total\"} 1\n", "abc1234")
      assert out =~ "no lei_build_info"
    end

    test "it is wired into the monitor" do
      # A check nothing invokes is not a check.
      monitor = File.read!(Path.expand("../../../../.github/workflows/monitor.yml", __DIR__))

      assert monitor =~ "scripts/check-deployed-sha.sh",
             "the deployed-sha check is not wired into the monitor"
    end

    test "the deploy passes the sha into the image" do
      # Without the build arg the gauge is `unknown` on every deploy, and the
      # check above fails forever. The two have to move together.
      deploy = File.read!(Path.expand("../../../../.github/workflows/deploy.yml", __DIR__))
      dockerfile = File.read!(Path.expand("../../Dockerfile", __DIR__))

      assert deploy =~ "--build-arg LEI_BUILD_SHA=",
             "the deploy does not pass LEI_BUILD_SHA, so the gauge would always be unknown"

      assert dockerfile =~ "ARG LEI_BUILD_SHA",
             "the Dockerfile does not accept LEI_BUILD_SHA"
    end
  end
end
