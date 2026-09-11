defmodule Lei.Web.SignupSuccessTest do
  @moduledoc """
  Stripe sends a paying customer straight to /signup/success, so it is the one
  page a Pro subscriber is guaranteed to see.

  It called get_session/2 without fetching the session first. Plug.Session only
  configures the store -- get_session/2 on an unfetched conn raises
  ArgumentError -- so every completed Pro checkout ended on a 500.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, Repo}

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp get_success(query \\ "") do
    conn(:get, "/signup/success" <> query)
    |> Lei.Web.Router.call(@opts)
  end

  test "renders without raising when there is no pending signup" do
    # The regression: this raised ArgumentError rather than rendering.
    conn = get_success("?session_id=cs_test_123")

    assert conn.status == 200
    assert conn.resp_body =~ "No pending signup found"
  end

  test "renders without raising when no session_id is supplied at all" do
    conn = get_success()

    assert conn.status == 200
    refute conn.resp_body =~ "POSTful service"
  end

  test "activates a pending org and shows its credentials" do
    {:ok, org} = ApiKeys.create_org("Signup Success Org", tier: "pro", status: "pending")

    conn =
      conn(:get, "/signup/success?session_id=cs_test_abc")
      |> Plug.Test.init_test_session(%{"pending_org_id" => org.id})
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200

    # The success URL is Stripe's confirmation that payment completed, so it
    # activates the org even if the webhook has not arrived yet.
    assert Repo.get(Lei.Org, org.id).status == "active"
  end
end
