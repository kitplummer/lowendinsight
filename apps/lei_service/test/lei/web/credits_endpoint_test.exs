defmodule Lei.Web.CreditsEndpointTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Credits, UsageTracker}

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Credits API #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "credits", ["analyze"])

    %{org: org, raw_key: raw_key, api_key: api_key}
  end

  defp get_credits(key) do
    conn = conn(:get, "/v1/credits")

    conn =
      if key,
        do: put_req_header(conn, "authorization", "Bearer #{key}"),
        else: conn

    Lei.Web.Router.call(conn, @opts)
  end

  defp body(conn), do: Poison.decode!(conn.resp_body)

  describe "authentication" do
    test "requires an API key" do
      conn = get_credits(nil)

      assert conn.status == 401
    end

    test "rejects an unknown key" do
      conn = get_credits("lei_not_a_real_key")

      assert conn.status == 401
    end
  end

  describe "the balance" do
    test "reports zero for a new org", %{raw_key: key} do
      conn = get_credits(key)

      assert conn.status == 200
      assert body(conn)["balance"] == 0
      assert body(conn)["entries"] == []
    end

    test "reports grants and debits", %{org: org, raw_key: key, api_key: api_key} do
      {:ok, _} = Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_api")
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 10, 0)

      payload = body(get_credits(key))

      assert payload["balance"] == 14_950
      assert length(payload["entries"]) == 2
    end

    test "states what a credit is worth rather than leaving it to be guessed", %{raw_key: key} do
      payload = body(get_credits(key))

      assert payload["credit_value_usd"] == "0.001"
      assert payload["pricing"]["cache_hit"] == 5
      assert payload["pricing"]["cache_miss"] == 50
    end

    test "entries are newest first", %{org: org, raw_key: key} do
      {:ok, _} = Credits.grant(org.id, 100, "adjustment:manual")
      {:ok, _} = Credits.grant(org.id, 200, "adjustment:manual")

      [first, second] = body(get_credits(key))["entries"]

      assert first["delta"] == 200
      assert second["delta"] == 100
    end
  end

  describe "it does not leak" do
    test "one org cannot see another's ledger", %{raw_key: key} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Credits Other #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _} = Credits.grant(other.id, 99_999, "purchase:stripe", external_ref: "pi_other")

      payload = body(get_credits(key))

      assert payload["balance"] == 0
      assert payload["entries"] == []
    end

    test "the org cannot be chosen by a parameter", %{raw_key: key} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Credits Target #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _} = Credits.grant(other.id, 77_777, "purchase:stripe", external_ref: "pi_target")

      # org_id comes from the API key and nothing else. Asserted because a
      # balance is money, and "scoped by construction" is worth proving rather
      # than describing.
      conn =
        conn(:get, "/v1/credits?org_id=#{other.id}")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      assert Poison.decode!(conn.resp_body)["balance"] == 0
    end

    test "payment references are not exposed", %{org: org, raw_key: key} do
      # external_ref is a Stripe payment intent or an on-chain transaction
      # hash. The balance is explicable without it.
      {:ok, _} = Credits.grant(org.id, 100, "purchase:stripe", external_ref: "pi_secret_ref")

      assert conn = get_credits(key)
      refute conn.resp_body =~ "pi_secret_ref"
      refute conn.resp_body =~ "external_ref"
    end
  end
end
