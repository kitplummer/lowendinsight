defmodule LeiService.OneRateLimitTest do
  @moduledoc """
  An API key has one allowance per minute, the one its tier has, on every
  analysis route -- and the signup page says what it is.

  The signup page promised 60 requests a minute. What ran (2026-10-27):

    * `POST /v1/analyze/batch` -- 60 free, 600 Pro, per key (`Lei.Auth`)
    * `POST /v1/analyze` -- 10, whatever the tier, in a limiter of its own
      written in March, before there were tiers
    * `POST /v1/analyze/sbom` -- no per-key limit: that limiter matched the
      path `/v1/analyze` exactly

  Driven through `LeiService.Endpoint`, which is what production serves:
  the batch route is forwarded from it to `Lei.Web.Router`, and the other two
  are its own. Limits are configured small so the tests send a handful of
  requests; the bodies are invalid so nothing is analysed or charged.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Repo}

  @opts LeiService.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    saved = Application.get_env(:lei_service, :rate_limits)

    Application.put_env(
      :lei_service,
      :rate_limits,
      Map.merge(saved, %{free: 3, pro: 6})
    )

    on_exit(fn ->
      Application.put_env(:lei_service, :rate_limits, saved)
      Lei.RateLimiter.clear()
    end)

    %{free: key_for("free"), pro: key_for("pro")}
  end

  defp key_for(tier) do
    # A Pro org cannot be active without a Stripe customer (Lei.Org).
    stripe = if tier == "pro", do: [stripe_customer_id: "cus_test_limit"], else: []

    {:ok, org} =
      ApiKeys.create_org(
        "Limit #{tier} #{System.unique_integer([:positive])}",
        [tier: tier, status: "active"] ++ stripe
      )

    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "k", ["analyze"])
    raw_key
  end

  defp post(path, key) do
    conn(:post, path, Poison.encode!(%{}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> key)
    |> LeiService.Endpoint.call(@opts)
  end

  defp statuses(path, key, n), do: for(_ <- 1..n, do: post(path, key).status)

  test "/v1/analyze allows the tier's limit, not a fixed one", %{free: key} do
    allowed = statuses("/v1/analyze", key, 3)

    refute 429 in allowed, "refused within the free allowance: #{inspect(allowed)}"
    assert post("/v1/analyze", key).status == 429, "allowed past the free allowance"
  end

  test "a Pro key gets the Pro limit on /v1/analyze", %{pro: key} do
    refute 429 in statuses("/v1/analyze", key, 6)
    assert post("/v1/analyze", key).status == 429
  end

  test "/v1/analyze/sbom is limited too", %{free: key} do
    statuses("/v1/analyze/sbom", key, 3)

    assert post("/v1/analyze/sbom", key).status == 429,
           "the SBOM route had no per-key limit"
  end

  test "every analysis route draws on one allowance", %{free: key} do
    # One of each, then the fourth request is over a limit of three, whichever
    # route it is on.
    assert post("/v1/analyze/batch", key).status != 429
    assert post("/v1/analyze", key).status != 429
    assert post("/v1/analyze/sbom", key).status != 429

    assert post("/v1/analyze", key).status == 429,
           "each route counted separately, so a key had three allowances"
  end

  test "a refusal says when to come back", %{free: key} do
    statuses("/v1/analyze", key, 3)
    conn = post("/v1/analyze", key)

    assert conn.status == 429
    assert [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) in 1..60
  end

  test "the signup page states the limit that is enforced" do
    body = conn(:get, "/signup") |> LeiService.Endpoint.call(@opts) |> Map.fetch!(:resp_body)

    assert body =~ "3 requests/min",
           "the page states a number of its own rather than the configured limit"

    refute body =~ "60 requests/min"
  end

  test "and the Pro limit, where the page offers Pro" do
    # Pro is not offered during beta (ADR-007), so read it with billing on.
    saved = Application.get_env(:lei_service, :billing_mode)
    Application.put_env(:lei_service, :billing_mode, :charge)
    on_exit(fn -> Application.put_env(:lei_service, :billing_mode, saved) end)

    body = conn(:get, "/signup") |> LeiService.Endpoint.call(@opts) |> Map.fetch!(:resp_body)

    assert body =~ "6 requests/min"
    refute body =~ "600 requests/min"
  end
end
