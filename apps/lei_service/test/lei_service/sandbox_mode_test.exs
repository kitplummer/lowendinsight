defmodule LeiService.SandboxModeTest do
  @moduledoc """
  No test may be `async: true` and put the sandbox into shared mode.

  Shared mode hands one connection to **every** process on the node. That is
  what makes it useful — the processes an endpoint spawns can reach the
  connection without being allowed individually — and it is exactly why it
  cannot run alongside concurrent tests. Another async test checks out the
  shared connection, checks it in when it finishes, and the owner is left
  holding nothing:

      EndpointTest "returns 422 with an invalid json payload"
        checked in the connection owned by
      ObanSchemaVersionTest "the migrated Oban schema matches the installed Oban"

  That failure reached `main` on 2026-09-21 from a documentation-only merge,
  which is the tell: it had nothing to do with the change and everything to do
  with which tests happened to interleave. One file was miscombined out of the
  71 that use shared mode, and it was enough to make the suite unreliable.

  This is checked by reading the test sources rather than by running anything,
  because the failure is a race — a test for it would be as unreliable as the
  thing it tests, and would pass most of the time.
  """
  use ExUnit.Case, async: true

  @test_root Path.expand("../..", __DIR__)

  # This file is excluded by name because it contains both patterns as string
  # literals and would otherwise report itself. Excluding by name rather than
  # loosening the match keeps the search exact -- a looser pattern would let a
  # real offender through, which is the failure this exists to prevent.
  @self __ENV__.file

  defp test_files do
    Path.join(@test_root, "test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.reject(&(Path.expand(&1) == Path.expand(@self)))
  end

  test "there are test files to check" do
    # An empty sweep would make every assertion below vacuously true, which is
    # the shape of check that passes by examining nothing.
    assert length(test_files()) > 20
  end

  test "no async test puts the sandbox into shared mode" do
    offenders =
      test_files()
      |> Enum.filter(fn path ->
        source = File.read!(path)

        String.contains?(source, "use ExUnit.Case, async: true") and
          String.contains?(source, "shared, self()")
      end)
      |> Enum.map(&Path.relative_to(&1, @test_root))

    assert offenders == [],
           """
           These tests are async and put the sandbox into shared mode, which
           hands their connection to every other process on the node:

             #{Enum.join(offenders, "\n  ")}

           Either make the file async: false, or allow the specific processes
           that need the connection with Sandbox.allow/3 instead of sharing it.
           """
  end

  test "shared mode is still in use, so this check is not guarding an empty set" do
    # If shared mode were removed everywhere the assertion above would pass for
    # a reason that has nothing to do with it being safe.
    users =
      test_files()
      |> Enum.count(&String.contains?(File.read!(&1), "shared, self()"))

    assert users > 10,
           "shared mode is no longer widely used; revisit whether this check earns its place"
  end
end
