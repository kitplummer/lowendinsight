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

    test "does not include weekly on Monday" do
      monday = ~D[2026-02-09]
      tags = OCIClient.generate_tags(monday)
      refute "weekly" in tags
      assert length(tags) == 2
    end

    test "generates tags with default (today)" do
      tags = OCIClient.generate_tags()
      assert length(tags) >= 2
      assert "latest" in tags
    end
  end

  describe "parse_reference/1 additional cases" do
    test "parses reference with nested repository path" do
      {:ok, registry, repo, tag} =
        OCIClient.parse_reference("ghcr.io/org/sub/repo:v1.0")

      assert registry == "ghcr.io"
      assert repo == "org/sub/repo"
      assert tag == "v1.0"
    end

    test "returns error for empty string" do
      assert {:error, _} = OCIClient.parse_reference("")
    end

    test "parses reference with oci:// prefix and no tag" do
      {:ok, _registry, _repo, tag} =
        OCIClient.parse_reference("oci://ghcr.io/org/repo")

      assert tag == "latest"
    end
  end

  describe "pull_manifest/4" do
    @describetag :network

    test "returns error for nonexistent registry" do
      result = OCIClient.pull_manifest("nonexistent.example.com", "repo", "latest")
      assert {:error, _} = result
    end
  end

  describe "pull_blob/4" do
    @describetag :network

    test "returns error for nonexistent registry" do
      result = OCIClient.pull_blob("nonexistent.example.com", "repo", "sha256:abc123")
      assert {:error, _} = result
    end
  end

  describe "push/6" do
    @describetag :network

    test "returns error for nonexistent registry" do
      result =
        OCIClient.push(
          "nonexistent.example.com",
          "repo",
          ["latest"],
          "{}",
          [{"sha256:abc", "data"}]
        )

      assert {:error, _} = result
    end
  end
end
