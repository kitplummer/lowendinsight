defmodule LeiService.RequestScopeTest do
  @moduledoc """
  How many repositories one request may name (ADR-008, question 2).

  Before this, the only bound was the org's remaining quota — a billing control
  doing a capacity control's job. In beta the free-tier allowance was the sole
  thing between us and a 3,580-repository manifest; once billing is on, a funded
  org can ask for ten thousand in one call, occupying the whole analysis queue
  for twenty minutes while every other customer waits and nothing reports it.

  **Every route that names a list is driven here.** Two of them share
  `urls_analyzable/1` and the third has its own validation, which is exactly how
  a cap ends up applying to some of them. Asserting the module is called would
  not catch that; asking each route is what does.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys
  alias Lei.RequestScope

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Scope #{System.unique_integer([:positive])}", status: "active")

    {:ok, key, _} = ApiKeys.create_api_key(org, "analyze", ["analyze"])

    # A small cap, so the over-cap payloads stay small enough to be readable.
    previous = Application.get_env(:lei_service, :max_repositories_per_request)
    Application.put_env(:lei_service, :max_repositories_per_request, 3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lei_service, :max_repositories_per_request, previous),
        else: Application.delete_env(:lei_service, :max_repositories_per_request)
    end)

    %{key: key, cap: 3}
  end

  defp post(path, payload, key) do
    conn(:post, path, Poison.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> LeiService.Endpoint.call(@opts)
  end

  defp urls(n), do: for(i <- 1..n, do: "https://github.com/o/r#{i}")

  defp sbom(n) do
    %{
      "spdxVersion" => "SPDX-2.3",
      "packages" =>
        for i <- 1..n do
          %{
            "name" => "r#{i}",
            "externalRefs" => [
              %{"referenceType" => "purl", "referenceLocator" => "pkg:github/o/r#{i}"}
            ]
          }
        end
    }
  end

  defp dependencies(n),
    do: for(i <- 1..n, do: %{"ecosystem" => "npm", "package" => "p#{i}", "version" => "1.0.0"})

  describe "every route that names a list is capped" do
    test "POST /v1/analyze", %{key: key, cap: cap} do
      conn = post("/v1/analyze", %{urls: urls(cap + 1)}, key)

      assert conn.status == 422
      body = Poison.decode!(conn.resp_body)
      assert body["error"] == "too_many_repositories"
      assert body["limit"] == cap
      assert body["received"] == cap + 1
    end

    test "POST /v1/analyze/sbom", %{key: key, cap: cap} do
      conn = post("/v1/analyze/sbom", %{sbom: sbom(cap + 1)}, key)

      assert conn.status == 422
      assert Poison.decode!(conn.resp_body)["error"] == "too_many_repositories"
    end

    test "POST /v1/analyze/batch", %{key: key, cap: cap} do
      # Its own validation path, and the one a cap would be forgotten in.
      conn = post("/v1/analyze/batch", %{dependencies: dependencies(cap + 1)}, key)

      assert conn.status == 422
      body = Poison.decode!(conn.resp_body)
      assert body["error"] == "too_many_repositories"
      assert body["limit"] == cap
    end
  end

  describe "the refusal is actionable" do
    test "it names the count and the limit, so a caller can split the work", %{key: key} do
      conn = post("/v1/analyze", %{urls: urls(10)}, key)

      body = Poison.decode!(conn.resp_body)

      assert body["received"] == 10
      assert body["limit"] == 3
      assert body["message"] =~ "Split it"

      assert body["message"] =~ "3",
             "an agent told only 'too many' cannot work out what to send instead"
    end

    test "a request at the cap is served, not refused", %{key: key, cap: cap} do
      # Off-by-one in the wrong direction is a refusal of work we accepted
      # yesterday. The URLs are not analysable, so anything but 422-for-scope is
      # a pass here.
      conn = post("/v1/analyze", %{urls: urls(cap)}, key)

      refute Poison.decode!(conn.resp_body)["error"] == "too_many_repositories"
    end
  end

  describe "the cap itself" do
    test "zero or less is unlimited, for a deployment with its own queue" do
      # ADR-003: the library and the service are separable, and a self-hoster's
      # capacity is their own business.
      Application.put_env(:lei_service, :max_repositories_per_request, 0)
      assert RequestScope.check(10_000) == :ok

      Application.put_env(:lei_service, :max_repositories_per_request, -1)
      assert RequestScope.check(10_000) == :ok
    end

    test "the default is no larger than its own derivation" do
      # concurrency 5 x the 180 s a blocking request is already allowed, over a
      # p90 analysis of 1.62 s, is ~555. A cap above that lets one request hold
      # the whole queue for longer than the service permits any single request
      # to take. Raising it is only legitimate alongside the concurrency.
      Application.delete_env(:lei_service, :max_repositories_per_request)

      derived = trunc(5 * 180 / 1.62)

      assert RequestScope.max_repositories() <= derived,
             "the default cap exceeds the queue budget it was derived from"

      assert RequestScope.max_repositories() > 0
    end
  end
end
