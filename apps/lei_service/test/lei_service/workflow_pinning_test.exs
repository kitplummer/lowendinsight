defmodule LeiService.WorkflowPinningTest do
  @moduledoc """
  Third-party actions run with our credentials, so they are pinned to a commit.

  `superfly/flyctl-actions/setup-flyctl@master` with `version: latest` resolved
  both the action's code and the flyctl binary fresh on every run, in two
  workflows, one of which holds a Fly token scoped to the database app. It
  failed silently on 2026-09-23 -- no output, every later step skipped, no
  backup taken -- and nothing about the run said which version had run.

  flyctl publishes daily at 19:14 UTC and the backup runs at 03:39, so every
  nightly backup ran a build less than nine hours old. That is not the cause of
  any single failure we can prove; it is a dependency nobody chose, arriving
  unannounced, with a token in scope.

  A tag is not a pin: tags move, and `@master` is not even a tag.
  """
  use ExUnit.Case, async: true

  @workflows Path.expand("../../../../.github/workflows", __DIR__)

  # First-party. GitHub controls the namespace, and the repo pins them to major
  # tags deliberately so security patches arrive without a manual bump.
  @first_party ~r{^actions/}

  # The one exception, and it is a gap rather than a decision: this org enforces
  # SAML on its repositories, so the API will not resolve the tag to a commit
  # for us. v1.0.1 is at least an immutable-by-convention patch tag rather than
  # a moving major.
  @unresolvable ["defenseunicorns/setup-uds@v1.0.1"]

  defp workflow_files, do: Path.wildcard(Path.join(@workflows, "*.yml"))

  defp action_refs do
    for path <- workflow_files(),
        line <- File.read!(path) |> String.split("\n"),
        captures = Regex.run(~r/^\s*-?\s*uses:\s*(\S+)/, line),
        ref = Enum.at(captures, 1),
        not Regex.match?(@first_party, ref),
        do: {Path.basename(path), ref}
  end

  test "every third-party action is pinned to a commit sha" do
    offenders =
      for {file, ref} <- action_refs(),
          ref not in @unresolvable,
          not Regex.match?(~r/@[0-9a-f]{40}$/, ref),
          do: "#{file}: #{ref}"

    assert offenders == [],
           """
           These third-party actions are not pinned to a commit sha:

             #{Enum.join(offenders, "\n  ")}

           Resolve the tag and pin it, keeping the readable version in a
           trailing comment:

             gh api repos/OWNER/REPO/commits/TAG --jq .sha
           """
  end

  test "the flyctl binary is pinned too, not resolved as 'latest'" do
    # Pinning the action and leaving `version: latest` pins the wrapper and not
    # the thing it installs, which is the part that talks to Fly.
    for name <- ~w(backup.yml deploy.yml) do
      source = File.read!(Path.join(@workflows, name))

      if String.contains?(source, "setup-flyctl") do
        refute source =~ ~r/version:\s*latest/,
               "#{name} installs whatever flyctl was released most recently"

        assert source =~ ~r/version:\s*v\d+\.\d+\.\d+/,
               "#{name} does not pin a flyctl version"
      end
    end
  end

  test "the unresolvable list has not quietly grown" do
    # An allowlist is how this check stops being a check. One entry, for a
    # stated reason; a second one has to be argued for in a diff.
    assert length(@unresolvable) == 1
  end

  test "the check can actually see the workflows" do
    # A wildcard resolving to nothing would pass every assertion above while
    # examining no files.
    files = workflow_files()
    assert length(files) > 8
    assert Enum.any?(files, &String.ends_with?(&1, "backup.yml"))
    assert length(action_refs()) > 5
  end
end
