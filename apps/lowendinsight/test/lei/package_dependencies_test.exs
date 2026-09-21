defmodule Lei.PackageDependenciesTest do
  @moduledoc """
  The edges come from a response we already fetch (#263).

  `risk_rank` orders a manifest by how sick each dependency is. It does not
  know how much that sickness would hurt: a dead dependency in a test helper
  and a dead dependency on the request path score identically, and only the
  second is worth acting on first.

  In-degree within a customer's own manifest is a proxy for blast radius, and
  it needs edges the request does not carry — `valid_dependency?/1` accepts
  only ecosystem, package and version.

  `resolve/3` already fetches the registry document for the repository URL, and
  that same document declares the package's dependencies. We were receiving
  them and throwing them away, exactly as `github_trending` reads `size` and
  discards `pushed_at` from one GitHub response.

  The HTTP GET is injected, so nothing here reaches a registry.
  """
  use ExUnit.Case, async: true

  alias Lei.PackageRepository

  defp responder(body) do
    [get: fn _url -> {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(body)}} end]
  end

  describe "npm" do
    test "reads the current version's dependencies" do
      body = %{
        "dist-tags" => %{"latest" => "4.18.2"},
        "versions" => %{
          "4.18.2" => %{"dependencies" => %{"body-parser" => "1.20.1", "qs" => "6.11.0"}},
          "3.0.0" => %{"dependencies" => %{"ancient" => "0.1.0"}}
        }
      }

      assert {:ok, deps} = PackageRepository.dependencies("npm", "express", responder(body))
      assert Enum.sort(deps) == ["body-parser", "qs"]
    end

    test "a package with no dependencies declares none" do
      body = %{"dist-tags" => %{"latest" => "1.0.0"}, "versions" => %{"1.0.0" => %{}}}

      assert {:ok, []} = PackageRepository.dependencies("npm", "leftpad", responder(body))
    end
  end

  describe "hex" do
    test "reads the latest release's requirements" do
      body = %{
        "releases" => [
          %{"version" => "3.10.0", "requirements" => %{"decimal" => %{}, "jason" => %{}}}
        ]
      }

      assert {:ok, deps} = PackageRepository.dependencies("hex", "ecto", responder(body))
      assert Enum.sort(deps) == ["decimal", "jason"]
    end
  end

  describe "an ecosystem whose shape is not handled" do
    test "says so rather than answering with an empty list" do
      # "declares nothing" and "we did not look" must not read alike. A package
      # whose edges cannot be seen would otherwise appear to have none, and
      # sort as peripheral — which is the failure this whole ordering exists
      # to avoid.
      body = %{"info" => %{"project_urls" => %{"Source" => "https://github.com/x/y"}}}

      assert {:error, :unsupported} =
               PackageRepository.dependencies("pypi", "requests", responder(body))
    end
  end

  describe "when the registry cannot be reached" do
    test "the error is returned, not an empty list" do
      opts = [get: fn _url -> {:error, %HTTPoison.Error{reason: :timeout}} end]

      assert {:error, _} = PackageRepository.dependencies("npm", "express", opts)
    end

    test "an unknown ecosystem is refused before any request" do
      opts = [get: fn _url -> flunk("should not have been called") end]

      assert {:error, _} = PackageRepository.dependencies("cobol", "x", opts)
    end
  end
end
