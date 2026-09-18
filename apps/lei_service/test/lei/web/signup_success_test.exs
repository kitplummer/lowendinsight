defmodule Lei.Web.SignupSuccessTest do
  @moduledoc """
  Stripe sends a paying customer straight to /signup/success, so it is the one
  page a Pro subscriber is guaranteed to see.

  It called get_session/2 without fetching the session first. Plug.Session only
  configures the store -- get_session/2 on an unfetched conn raises
  ArgumentError -- so every completed Pro checkout ended on a 500.

  It then activated the org on arrival, on the theory that "the success URL is
  Stripe's confirmation that payment completed". It is not: it is a URL anyone
  can request. POST /signup with tier=pro sets the pending org in the session
  cookie before redirecting to Stripe, so skipping the checkout page and
  requesting /signup/success activated an unpaid, unmetered Pro org and handed
  out an admin key. Replaying the cookie minted a fresh key and recovery code on
  every visit, and re-activated an org the webhook had suspended.

  Activation now requires the Checkout Session, fetched from Stripe, to be
  complete, paid, and for this org. Credentials are issued once per org.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Mox

  alias Lei.{ApiKeys, Repo}

  setup :verify_on_exit!

  @opts Lei.Web.Router.init([])
  @key ~r/lei_[0-9a-f]{32}/

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp pending_org(status \\ "pending") do
    {:ok, org} =
      ApiKeys.create_org("Signup Success #{System.unique_integer([:positive])}",
        tier: "pro",
        status: status,
        # An already-active Pro org has necessarily been through Stripe, so it
        # holds a customer id -- Lei.Org will not let one exist without it.
        stripe_customer_id: if(status == "active", do: "cus_already_active")
      )

    org
  end

  defp visit(org_id, query) do
    conn = conn(:get, "/signup/success" <> query)
    conn = if org_id, do: init_test_session(conn, %{"pending_org_id" => org_id}), else: conn
    Lei.Web.Router.call(conn, @opts)
  end

  defp checkout(org, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "cs_test_paid",
        "object" => "checkout.session",
        "status" => "complete",
        "payment_status" => "paid",
        "customer" => "cus_signup",
        "subscription" => "sub_signup",
        "metadata" => %{"org_id" => to_string(org.id)}
      },
      overrides
    )
  end

  defp stripe_returns(result) do
    expect(Lei.StripeMock, :retrieve_checkout_session, fn "cs_test_paid" -> result end)
  end

  defp key_count(org), do: length(ApiKeys.list_keys(org))

  defp status(org), do: Repo.get(Lei.Org, org.id).status

  test "renders without raising when there is no pending signup" do
    conn = visit(nil, "?session_id=cs_test_123")

    assert conn.status == 200
    assert conn.resp_body =~ "No pending signup found"
  end

  describe "an unpaid visit activates nothing and issues nothing" do
    test "no session_id at all" do
      org = pending_org()
      conn = visit(org.id, "")

      assert conn.status == 200
      refute conn.resp_body =~ @key
      assert status(org) == "pending"
      assert key_count(org) == 0
    end

    test "a checkout Stripe says is not paid" do
      org = pending_org()
      stripe_returns({:ok, checkout(org, %{"status" => "open", "payment_status" => "unpaid"})})

      conn = visit(org.id, "?session_id=cs_test_paid")

      refute conn.resp_body =~ @key
      assert status(org) == "pending"
      assert key_count(org) == 0
    end

    test "a paid checkout for a different org" do
      org = pending_org()
      other = pending_org()
      stripe_returns({:ok, checkout(other)})

      conn = visit(org.id, "?session_id=cs_test_paid")

      refute conn.resp_body =~ @key
      assert status(org) == "pending"
      assert status(other) == "pending"
    end

    test "Stripe cannot be reached" do
      org = pending_org()
      stripe_returns({:error, {404, %{"error" => %{"code" => "resource_missing"}}}})

      conn = visit(org.id, "?session_id=cs_test_paid")

      refute conn.resp_body =~ @key
      assert status(org) == "pending"
    end

    test "a suspended org is not re-activated by an old paid checkout" do
      org = pending_org("suspended")
      stripe_returns({:ok, checkout(org)})

      conn = visit(org.id, "?session_id=cs_test_paid")

      refute conn.resp_body =~ @key
      assert status(org) == "suspended"
      assert key_count(org) == 0
    end
  end

  test "a paid checkout activates the org, records billing, and shows credentials" do
    org = pending_org()
    stripe_returns({:ok, checkout(org)})

    conn = visit(org.id, "?session_id=cs_test_paid")

    assert conn.status == 200
    assert conn.resp_body =~ @key

    org = Repo.get(Lei.Org, org.id)
    assert org.status == "active"
    assert org.stripe_customer_id == "cus_signup"
    assert org.stripe_subscription_id == "sub_signup"
    assert key_count(org) == 1
  end

  test "an org the webhook already activated still gets its credentials once" do
    org = pending_org("active")
    stripe_returns({:ok, checkout(org)})

    conn = visit(org.id, "?session_id=cs_test_paid")

    assert conn.resp_body =~ @key
    assert key_count(org) == 1
  end

  test "replaying the success visit does not mint more credentials" do
    org = pending_org()
    stub(Lei.StripeMock, :retrieve_checkout_session, fn _ -> {:ok, checkout(org)} end)

    assert visit(org.id, "?session_id=cs_test_paid").resp_body =~ @key

    replay = visit(org.id, "?session_id=cs_test_paid")

    refute replay.resp_body =~ @key
    assert replay.resp_body =~ "already issued"
    assert key_count(org) == 1
  end
end
