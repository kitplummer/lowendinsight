# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.OCIClientTest do
  use ExUnit.Case, async: true

  alias Lei.Cache.OCIClient

  describe "parse_reference/1" do
    test "parses oci:// prefixed reference" do
      {:ok, registry, repo, tag} =
        OCIClient.parse_reference("oci://ghcr.io/defenseunicorns/lei-cache:2026-02-05")

      assert registry == "ghcr.io"
      assert repo == "defenseunicorns/lei-cache"
      assert tag == "2026-02-05"
    end

    test "parses reference without oci:// prefix" do
      {:ok, registry, repo, tag} =
        OCIClient.parse_reference("ghcr.io/defenseunicorns/lei-cache:latest")

      assert registry == "ghcr.io"
      assert repo == "defenseunicorns/lei-cache"
      assert tag == "latest"
    end

    test "defaults to latest tag when omitted" do
      {:ok, _registry, _repo, tag} =
        OCIClient.parse_reference("ghcr.io/defenseunicorns/lei-cache")

      assert tag == "latest"
    end

    test "returns error for invalid reference" do
      assert {:error, _} = OCIClient.parse_reference("invalid")
    end
  end

  describe "generate_tags/1" do
    test "includes date and latest" do
      date = ~D[2026-02-05]
      tags = OCIClient.generate_tags(date)

      assert "2026-02-05" in tags
      assert "latest" in tags
    end

    test "includes weekly on Sundays" do
      # 2026-02-08 is a Sunday
      sunday = ~D[2026-02-08]
      tags = OCIClient.generate_tags(sunday)

      assert "weekly" in tags
    end

    test "does not include weekly on non-Sundays" do
      # 2026-02-05 is a Thursday
      thursday = ~D[2026-02-05]
      tags = OCIClient.generate_tags(thursday)

      refute "weekly" in tags
    end
  end
end
