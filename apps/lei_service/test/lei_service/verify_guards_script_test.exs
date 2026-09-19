defmodule LeiService.VerifyGuardsScriptTest do
  @moduledoc """
  The thing that verifies the guards is itself verified.

  `scripts/verify-guards.sh` decides whether a guard is real, so everything
  else in `scripts/mutations.json` rests on it being right. For most of its
  life it was not: any non-zero exit from the guarding test counted as "the
  guard caught the mutation", so a test file with a syntax error, a typo in
  `guarded_by`, or a mutation that broke compilation all reported PASS. Four
  guards were verified that way on 2026-09-18 without a single test running.

  It was the last thing in the repository asserting something about
  correctness with nothing asserting anything about it — the argument for
  leaving it that way was that checking a shell script with a shell script has
  diminishing returns, which is a judgement rather than a reason.

  `mix` is replaced on PATH by a stub that returns a scripted exit code and
  output per call, so each classification is exercised without compiling
  anything. The same approach `Lei.Acp`'s notify script test uses for `curl`.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/verify-guards.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "guards-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "app"))

    # Scripted mix: line N of "script" is the Nth invocation, as "code:output".
    File.write!(Path.join(dir, "bin/mix"), """
    #!/usr/bin/env bash
    if [ "$1" = "compile" ]; then
      # No text: the verdict comes from this exit code alone.
      exit "$(cat "#{dir}/compile_code" 2>/dev/null || echo 0)"
    fi

    n=$(cat "#{dir}/calls" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "#{dir}/calls"
    line=$(sed -n "${n}p" "#{dir}/script")
    code="${line%%:*}"
    msg="${line#*:}"
    [ -n "$msg" ] && echo "$msg"
    exit "${code:-0}"
    """)

    File.chmod!(Path.join(dir, "bin/mix"), 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  # The file a mutation edits, and the manifest that points at it.
  defp fixture(dir, source, find, replace) do
    File.write!(Path.join(dir, "app/subject.ex"), source)

    # The script validates the manifest before running anything, including
    # that each guarding test exists -- a safeguard of its own, and one this
    # fixture has to satisfy. Its contents never matter: mix is stubbed.
    File.mkdir_p!(Path.join(dir, "app/test"))
    File.write!(Path.join(dir, "app/test/fixture_test.exs"), "# stubbed\n")

    manifest = %{
      "mutations" => [
        %{
          "id" => "fixture-guard",
          "bug" => "a fixture, for testing the verifier itself",
          "file" => "app/subject.ex",
          "find" => find,
          "replace" => replace,
          "guarded_by" => "test/fixture_test.exs",
          "app" => "app"
        }
      ]
    }

    File.write!(Path.join(dir, "manifest.json"), Poison.encode!(manifest))
  end

  defp mix_returns(dir, results),
    do: File.write!(Path.join(dir, "script"), Enum.join(results, "\n"))

  defp run(dir) do
    {out, code} =
      System.cmd("bash", [@script, "fixture-guard"],
        cd: dir,
        env: [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"GUARD_MANIFEST", Path.join(dir, "manifest.json")}
        ],
        stderr_to_stdout: true
      )

    {out, code}
  end

  defp subject(dir), do: File.read!(Path.join(dir, "app/subject.ex"))

  describe "a guard that genuinely catches its mutation" do
    test "passes, and exits 0", %{dir: dir} do
      fixture(dir, "def value, do: :correct\n", ":correct", ":wrong")
      # baseline passes, mutated run fails as a test
      mix_returns(dir, ["0:", "1:  1) test the value is correct (FixtureTest)"])

      {out, code} = run(dir)

      assert out =~ "PASS:"
      assert out =~ "1 verified, 0 unguarded, 0 stale, 0 broken, 0 inconclusive"
      assert code == 0
    end
  end

  describe "a guard test that does not pass to begin with" do
    # The defect this script had. A test already failing fails after the
    # mutation too, and that failure says nothing about the guard.
    test "is BROKEN, not verified", %{dir: dir} do
      fixture(dir, "def value, do: :correct\n", ":correct", ":wrong")
      mix_returns(dir, ["1:the guard test is already failing"])

      {out, code} = run(dir)

      assert out =~ "BROKEN:"
      refute out =~ "PASS:"
      assert out =~ "0 verified"
      assert code == 1
    end

    test "does not even apply the mutation", %{dir: dir} do
      original = "def value, do: :correct\n"
      fixture(dir, original, ":correct", ":wrong")
      mix_returns(dir, ["1:already failing"])

      run(dir)

      assert subject(dir) == original
    end
  end

  describe "a mutation that stops the code compiling" do
    # Exits non-zero without running a test, which this script used to count
    # as proof. Nothing was demonstrated, so it is inconclusive.
    test "is INCONCLUSIVE, not verified", %{dir: dir} do
      fixture(dir, "def value, do: :correct\n", ":correct", ":wrong")
      mix_returns(dir, ["0:", "1:a test failure nobody should reach"])
      File.write!(Path.join(dir, "compile_code"), "1")

      {out, code} = run(dir)

      assert out =~ "INCONCLUSIVE:"
      refute out =~ "PASS:"
      assert out =~ "0 verified"
      assert code == 1
    end

    test "a runtime error is not mistaken for a compile error", %{dir: dir} do
      # The first version of the detector matched "no such file or directory"
      # and reported a working guard -- one whose mutation removes a working
      # directory restore -- as inconclusive.
      fixture(dir, "def value, do: :correct\n", ":correct", ":wrong")

      mix_returns(dir, ["0:", "1:** (File.Error) could not get cwd: no such file or directory"])

      {out, code} = run(dir)

      assert out =~ "PASS:"
      refute out =~ "INCONCLUSIVE"
      assert code == 0
    end
  end

  describe "a guard that does not catch its mutation" do
    test "is reported unguarded", %{dir: dir} do
      fixture(dir, "def value, do: :correct\n", ":correct", ":wrong")
      mix_returns(dir, ["0:", "0:"])

      {out, code} = run(dir)

      assert out =~ "FAIL:"
      assert out =~ "0 verified, 1 unguarded"
      assert code == 1
    end
  end

  describe "a mutation that no longer matches its file" do
    # The baseline still runs first -- it is cached per guarding test, so in a
    # full run it is shared rather than wasted. What matters is that nothing
    # is verified and the file is left alone.
    test "is STALE, verifies nothing, and leaves the file untouched", %{dir: dir} do
      original = "def value, do: :something_else\n"
      fixture(dir, original, ":correct", ":wrong")
      mix_returns(dir, ["0:", "1:"])

      {out, code} = run(dir)

      assert out =~ "STALE:"
      assert out =~ "0 verified"
      refute out =~ "PASS:"
      assert code == 1
      assert File.read!(Path.join(dir, "app/subject.ex")) == original
    end
  end

  describe "whatever happens" do
    test "the mutated file is restored", %{dir: dir} do
      original = "def value, do: :correct\n"

      # Labelled rather than inspected, so fixture data never reaches a failure
      # message. It mattered when the script classified by grepping test
      # output: a fixture printed here was read back by the outer run as a
      # real compile error, and the same guard reported INCONCLUSIVE on one
      # run and PASS on the next. The script now compiles separately and reads
      # an exit code, so no output can change a verdict -- and keeping fixture
      # data out of messages costs nothing either way.
      scenarios = [
        {"a test failure", ["0:", "1:failed"]},
        {"a passing test", ["0:", "0:"]},
        {"a test failure after a clean compile", ["0:", "1:boom"]}
      ]

      for {label, results} <- scenarios do
        fixture(dir, original, ":correct", ":wrong")
        File.rm(Path.join(dir, "calls"))
        mix_returns(dir, results)

        run(dir)

        assert subject(dir) == original, "left the subject mutated after #{label}"
      end
    end
  end
end
