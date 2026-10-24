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
end
