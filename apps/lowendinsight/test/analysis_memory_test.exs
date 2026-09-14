defmodule AnalysisMemoryTest do
  @moduledoc """
  Analysing a repository's history must not allocate in proportion to every
  character of it (#158).

  Reproduced locally before the fix: elixir-lang/elixir (72 MB on disk,
  22,557 commits) took the VM from ~180 MB to 572 MB RSS inside
  GitModule.get_contributors, which split a 1.2 MB shortlog into one binary per
  codepoint to repair invalid UTF-8. On a 459 MB machine that is the process
  the kernel killed.
  """
  use ExUnit.Case, async: true

  # The implementation that was replaced, kept as the oracle for equivalence.
  defp old_repair(binary) do
    binary
    |> String.codepoints()
    |> Enum.map(fn x ->
      if !String.valid?(x), do: Enum.join(for(<<c <- x>>, do: <<c::utf8>>)), else: x
    end)
    |> Enum.join()
  end

  describe "GitHelper.repair_utf8/1" do
    test "matches the old implementation byte for byte" do
      samples = [
        "",
        "plain ascii",
        "valid ünïcödé — 日本語 🦀",
        <<"Jos", 0xE9, " <jose@example.com>">>,
        <<0xFF, 0xFE, "abc", 0x80>>,
        # Truncated multi-byte sequences, mid-string and at the end.
        <<"a", 0xE2, 0x82, "b">>,
        <<"end", 0xF0, 0x9F, 0xA6>>,
        <<0xC3>>,
        # Overlong and surrogate encodings are invalid UTF-8 too.
        <<0xC0, 0xAF, 0xED, 0xA0, 0x80>>
      ]

      random =
        for _ <- 1..300 do
          :crypto.strong_rand_bytes(:rand.uniform(64))
        end

      for sample <- samples ++ random do
        assert GitHelper.repair_utf8(sample) == old_repair(sample),
               "differs for #{inspect(sample, binaries: :as_binaries)}"

        assert String.valid?(GitHelper.repair_utf8(sample))
      end
    end

    test "returns valid input without copying it" do
      big = String.duplicate("Some Author <a@example.com> (3):\n      commit subject\n", 20_000)
      assert :erts_debug.same(GitHelper.repair_utf8(big), big)
    end

    test "repairs a large shortlog within a bounded heap" do
      # About the size of elixir-lang/elixir's shortlog, with invalid bytes
      # scattered through it so the fast path does not apply. The old
      # implementation needs hundreds of megabytes here; a process capped at
      # 64 MB of heap is killed if the regression returns.
      line =
        <<"Jos", 0xE9, " Valim <jose@example.com> (1):\n      Fix a thing in the compiler\n">>

      shortlog = String.duplicate(line, 18_000)
      assert byte_size(shortlog) > 1_200_000

      parent = self()

      {pid, ref} =
        :erlang.spawn_opt(
          fn -> send(parent, {:repaired, byte_size(GitHelper.repair_utf8(shortlog))}) end,
          [
            :monitor,
            max_heap_size: %{size: div(64 * 1_048_576, 8), kill: true, error_logger: false}
          ]
        )

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
      assert reason == :normal, "repair exceeded a 64 MB heap (#{inspect(reason)})"
      assert_received {:repaired, size}
      assert size > byte_size(shortlog)
    end
  end

  describe "GitModule.get_commits_with_trailers/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei_trailers_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      env = fn email ->
        [
          {"GIT_AUTHOR_NAME", email},
          {"GIT_AUTHOR_EMAIL", email},
          {"GIT_COMMITTER_NAME", email},
          {"GIT_COMMITTER_EMAIL", email}
        ]
      end

      commit = fn email, message ->
        File.write!(Path.join(dir, "f.txt"), message)
        System.cmd("git", ["add", "."], cd: dir)
        System.cmd("git", ["commit", "-q", "-m", message], cd: dir, env: env.(email))
      end

      System.cmd("git", ["init", "-q"], cd: dir)
      commit.("human@example.com", "plain commit, no trailers")
      commit.("human@example.com", "feature\n\nCo-Authored-By: Claude <noreply@anthropic.com>")

      commit.(
        "other@example.com",
        "lowercase trailer\n\nco-authored-by: GitHub Copilot <copilot@github.com>"
      )

      commit.("other@example.com", "mentions co-authors in prose but no trailer")

      {:ok, repo} = GitModule.get_repo(dir)
      %{repo: repo}
    end

    test "returns every commit that can carry a co-author, and nothing else", %{repo: repo} do
      {:ok, commits} = GitModule.get_commits_with_trailers(repo)

      assert Enum.sort_by(commits, & &1.author_email) |> Enum.map(& &1.author_email) ==
               ["human@example.com", "other@example.com"]

      assert Enum.all?(commits, &(&1.body =~ ~r/Co-Authored-By:/i))
    end

    test "detection over the filtered commits finds the same co-authors as over all of them",
         %{repo: repo} do
      {:ok, filtered} = GitModule.get_commits_with_trailers(repo)

      # Every commit body, the way the replaced call read them.
      {all_raw, 0} =
        System.cmd("git", ["log", "--pretty=format:%ae\t%B---LEI_SEPARATOR---"], cd: repo.path)

      all =
        all_raw
        |> String.split("---LEI_SEPARATOR---")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn e ->
          [email, body] = String.split(e, "\t", parts: 2)
          %{author_email: email, body: body}
        end)

      detect = fn commits, email ->
        commits
        |> Enum.filter(&(&1.author_email == email))
        |> Enum.map(& &1.body)
        |> Lei.AgenticDetector.detect_ai_coauthors()
      end

      for email <- ["human@example.com", "other@example.com"] do
        assert detect.(filtered, email) == detect.(all, email)
      end

      assert detect.(filtered, "human@example.com") != []
    end
  end
end
