defmodule LeiService.TenantIsolationTest do
  @moduledoc """
  An org's credentials act on that org only; platform operations need an
  operator (security, 2026-09-14).

  Signup gives every new org a key with the "admin" scope -- admin *of that
  org*, for its dashboard. The API treated "admin" as a platform permission and
  the org key routes never checked ownership, so any stranger's signup key
  could mint a key for any other org, list or revoke its keys, and import or
  export the shared cache. Driven through LeiService.Endpoint, the
  deployed stack.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    # In production both auth plugs verify operator JWTs with the same secret
    # (config/runtime.exs); test config gives them different defaults.
    previous = Application.get_env(:lei_service, :jwt_secret)

    Application.put_env(
      :lei_service,
      :jwt_secret,
      Application.get_env(:lei_service, :jwt_secret)
    )

    on_exit(fn -> Application.put_env(:lei_service, :jwt_secret, previous) end)

    victim = signup("Victim #{System.unique_integer([:positive])}")
    stranger = signup("Stranger #{System.unique_integer([:positive])}")
    %{victim: victim, stranger: stranger}
  end

  # What /signup issues.
  defp signup(name) do
    {:ok, org} = ApiKeys.create_org(name, tier: "free", status: "active")
    {:ok, raw, key} = ApiKeys.create_api_key(org, "admin", ["admin", "analyze"])
    %{org: org, raw: raw, key: key}
  end

  defp operator_jwt do
    signer = Joken.Signer.create("HS256", Application.get_env(:lei_service, :jwt_secret))
    {:ok, token, _} = Joken.generate_and_sign(%{}, operator_claims(), signer)
    token
  end

  defp request(method, path, bearer, body \\ nil) do
    c = if body, do: conn(method, path, Poison.encode!(body)), else: conn(method, path)

    c
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> LeiService.Endpoint.call(@opts)
  end

  describe "org keys belong to their org" do
    test "a stranger cannot mint a key for another org", %{victim: v, stranger: s} do
      conn =
        request(:post, "/v1/orgs/#{v.org.slug}/keys", s.raw, %{
          name: "mine now",
          scopes: ["admin"]
        })

      # Indistinguishable from an org that does not exist: no slug enumeration.
      assert conn.status == 404
      assert Poison.decode!(conn.resp_body)["error"] == "org not found"
      assert length(ApiKeys.list_keys(v.org)) == 1
    end

    test "a stranger cannot list another org's keys", %{victim: v, stranger: s} do
      conn = request(:get, "/v1/orgs/#{v.org.slug}/keys", s.raw)
      assert conn.status == 404
      refute conn.resp_body =~ v.key.key_prefix
    end

    test "a stranger cannot revoke another org's key, through their own slug either", %{
      victim: v,
      stranger: s
    } do
      assert request(:delete, "/v1/orgs/#{v.org.slug}/keys/#{v.key.id}", s.raw).status == 404
      # The key id is checked against the org in the path, not just looked up.
      assert request(:delete, "/v1/orgs/#{s.org.slug}/keys/#{v.key.id}", s.raw).status == 404

      assert Lei.Repo.get(Lei.ApiKey, v.key.id).active
    end

    test "an analyze-only key cannot revoke keys at all, even its own org's", %{victim: v} do
      {:ok, analyze_raw, _} = ApiKeys.create_api_key(v.org, "worker", ["analyze"])

      conn = request(:delete, "/v1/orgs/#{v.org.slug}/keys/#{v.key.id}", analyze_raw)
      assert conn.status in [403, 404]
      assert Lei.Repo.get(Lei.ApiKey, v.key.id).active
    end

    test "an org admin manages its own keys", %{victim: v} do
      created =
        request(:post, "/v1/orgs/#{v.org.slug}/keys", v.raw, %{name: "ci", scopes: ["analyze"]})

      assert created.status == 201
      id = ApiKeys.list_keys(v.org) |> Enum.find(&(&1.name == "ci")) |> Map.fetch!(:id)

      assert request(:get, "/v1/orgs/#{v.org.slug}/keys", v.raw).status == 200
      assert request(:delete, "/v1/orgs/#{v.org.slug}/keys/#{id}", v.raw).status == 200
    end

    test "an org admin cannot grant itself a platform scope", %{victim: v} do
      conn =
        request(:post, "/v1/orgs/#{v.org.slug}/keys", v.raw, %{
          name: "escalate",
          scopes: ["cache"]
        })

      assert conn.status == 403
      refute Enum.any?(ApiKeys.list_keys(v.org), &("cache" in &1.scopes))
    end

    test "an operator can manage any org's keys", %{victim: v} do
      assert request(:post, "/v1/orgs/#{v.org.slug}/keys", operator_jwt(), %{
               name: "ops",
               scopes: ["cache"]
             }).status == 201
    end
  end

  describe "platform operations need an operator, not an org admin" do
    test "a signup key cannot export, import or invalidate the shared cache", %{stranger: s} do
      assert request(:get, "/v1/cache/export", s.raw).status == 403
      assert request(:post, "/v1/cache/import", s.raw, %{entries: []}).status == 403

      assert request(:post, "/v1/cache/invalidate", s.raw, %{url: "https://github.com/a/b"}).status ==
               403
    end

    test "a cache-scoped key still can, as the canary does", %{victim: v} do
      {:ok, cache_raw, _} = ApiKeys.create_api_key(v.org, "deploy-canary", ["cache"])

      assert request(:post, "/v1/cache/invalidate", cache_raw, %{url: "https://github.com/a/b"}).status ==
               200
    end

    test "a signup key cannot create orgs", %{stranger: s} do
      assert request(:post, "/v1/orgs", s.raw, %{name: "made by a stranger"}).status == 403
    end

    test "an operator can create orgs" do
      assert request(:post, "/v1/orgs", operator_jwt(), %{
               name: "ops-created #{System.unique_integer([:positive])}"
             }).status == 201
    end
  end

  # An operator token needs an expiry now: one without it is refused, and one
  # too far out is too (Lei.OperatorToken).
  defp operator_claims do
    %{"exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}
  end
end
