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
  # tags deliberately so security patches arrive without a manual bump. A
  # `./` reference is a workflow in this repository, at this commit.
  @first_party ~r{^(actions/|\./)}

  # Actions whose tag cannot be resolved to a commit. setup-uds was here because
  # the org enforces SAML on the API; its public tag listing resolves without
  # authentication, and it is pinned now. Empty, and it stays that way unless
  # an entry is argued for in a diff.
  @unresolvable []

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
    # An allowlist is how this check stops being a check.
    assert @unresolvable == []
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
