# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.SbomParserTest do
  use ExUnit.Case, async: true

  alias LowendinsightGet.SbomParser

  describe "CycloneDX parsing" do
    test "extracts URLs from externalReferences" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.4",
        "components" => [
          %{
            "name" => "my-lib",
            "version" => "1.0.0",
            "externalReferences" => [
              %{"type" => "vcs", "url" => "https://github.com/owner/repo"},
              %{"type" => "website", "url" => "https://example.com"}
            ]
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
      refute "https://example.com" in urls
    end

    test "extracts URLs from github purl" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "repo",
            "purl" => "pkg:github/owner/repo@v1.0.0"
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
    end

    test "extracts URLs from gitlab purl" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "myproject",
            "purl" => "pkg:gitlab/myorg/myproject@2.0.0"
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://gitlab.com/myorg/myproject" in urls
    end

    test "handles empty components" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => []
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert urls == []
    end

    test "deduplicates URLs" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "lib1",
            "purl" => "pkg:github/owner/repo@v1.0.0"
          },
          %{
            "name" => "lib2",
            "externalReferences" => [
              %{"type" => "vcs", "url" => "https://github.com/owner/repo"}
            ]
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert length(urls) == 1
      assert "https://github.com/owner/repo" in urls
    end
  end

  describe "SPDX parsing" do
    test "extracts URLs from externalRefs with purl" do
      sbom = %{
        "spdxVersion" => "SPDX-2.3",
        "packages" => [
          %{
            "name" => "my-package",
            "externalRefs" => [
              %{
                "referenceType" => "purl",
                "referenceLocator" => "pkg:github/owner/repo@1.0.0"
              }
            ]
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
    end

    test "extracts URLs from downloadLocation" do
      sbom = %{
        "spdxVersion" => "SPDX-2.3",
        "packages" => [
          %{
            "name" => "my-package",
            "downloadLocation" => "https://github.com/owner/repo/archive/v1.0.0.tar.gz"
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
    end

    test "ignores NOASSERTION downloadLocation" do
      sbom = %{
        "spdxVersion" => "SPDX-2.3",
        "packages" => [
          %{
            "name" => "my-package",
            "downloadLocation" => "NOASSERTION"
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert urls == []
    end

    test "handles empty packages" do
      sbom = %{
        "spdxVersion" => "SPDX-2.3",
        "packages" => []
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert urls == []
    end
  end

  describe "format detection" do
    test "returns error for unrecognized format" do
      sbom = %{"unknown" => "format"}

      {:error, reason} = SbomParser.parse(sbom)
      assert reason =~ "unrecognized SBOM format"
    end

    test "returns error for invalid JSON string" do
      {:error, reason} = SbomParser.parse("not valid json")
      assert reason == "invalid JSON"
    end
  end

  describe "purl parsing" do
    test "handles URL-encoded namespaces" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "scoped-package",
            "purl" => "pkg:github/%40scoped/package@1.0.0"
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/@scoped/package" in urls
    end
  end

  describe "URL normalization" do
    test "removes trailing .git" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "repo",
            "externalReferences" => [
              %{"type" => "vcs", "url" => "https://github.com/owner/repo.git"}
            ]
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
    end

    test "removes query string and fragment" do
      sbom = %{
        "bomFormat" => "CycloneDX",
        "components" => [
          %{
            "name" => "repo",
            "externalReferences" => [
              %{"type" => "vcs", "url" => "https://github.com/owner/repo?ref=main#readme"}
            ]
          }
        ]
      }

      {:ok, urls} = SbomParser.parse(sbom)
      assert "https://github.com/owner/repo" in urls
    end
  end
end
