defmodule LeiService.OneVersionTest do
  @moduledoc """
  The library, the service and the umbrella are one release, with one version.

  The web UI footer, `GET /v1/health` and `/openapi.json` report the service's
  version; Hex, the images and the CHANGELOG use the library's. They had
  drifted to 0.10.0 and 0.15.0, so production said `v0.10.0` while the code it
  ran was two library releases later. release.yml checks the tag against the
  library, so this keeps the other two on it.
  """
  use ExUnit.Case, async: true

  @umbrella Path.expand("../../../../mix.exs", __DIR__)

  test "the service is the library's version" do
    assert to_string(Application.spec(:lei_service, :vsn)) ==
             to_string(Application.spec(:lowendinsight, :vsn))
  end

  test "the umbrella is the library's version" do
    [_, umbrella] = Regex.run(~r/version:\s*"([^"]+)"/, File.read!(@umbrella))
    assert umbrella == to_string(Application.spec(:lowendinsight, :vsn))
  end

  # The Marketplace and Open VSX accept only x.y.z, so a beta cannot be the
  # extension's version verbatim. 0.16.0-beta.N ships as 0.16.N, flagged
  # pre-release; release.yml publishes under that number and this keeps the
  # file on it. A stable release must bump the minor: 0.16.0 after 0.16.N
  # would be lower than every beta of its own series, which the registries
  # refuse.
  @extension Path.expand("../../vscode-lowendinsight/package.json", __DIR__)

  test "the editor extension is the library's version, in registry form" do
    version = to_string(Application.spec(:lowendinsight, :vsn))
    package = File.read!(@extension) |> Jason.decode!()

    expected =
      case Regex.run(~r/^(\d+)\.(\d+)\.0-beta\.(\d+)$/, version) do
        [_, major, minor, beta] -> "#{major}.#{minor}.#{beta}"
        nil -> version
      end

    assert package["version"] == expected,
           "the extension is #{package["version"]}; #{version} ships as #{expected}"

    assert package["publisher"] == "revolve"
    assert package["preview"] == String.contains?(version, "-")
  end
end
