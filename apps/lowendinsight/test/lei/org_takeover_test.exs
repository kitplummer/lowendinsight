defmodule Lei.OrgTakeoverTest do
  @moduledoc """
  Signup and ACP completion are unauthenticated and both mint an
  admin-scoped API key for whatever org they are handed.

  They used to call find_or_create_org/2, which returns an *existing* org when
  the slug matches. Submitting the name of an existing organisation therefore
  yielded a fresh admin key for it -- unauthenticated access to someone else's
  org, its keys, and its usage.

  These pin the create-only behaviour that replaced it.
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

  describe "create_org/2" do
    test "refuses a name that already exists" do
      {:ok, _} = ApiKeys.create_org("Acme Corp", tier: "free", status: "active")

      assert {:error, :name_taken} = ApiKeys.create_org("Acme Corp", tier: "free")
    end

    test "refuses a name that slugifies onto an existing org" do
      {:ok, _} = ApiKeys.create_org("Acme Corp", tier: "free", status: "active")

      # Both slugify to "acme-corp"; matching on the raw name would miss this.
      assert {:error, :name_taken} = ApiKeys.create_org("ACME   corp!!", tier: "free")
    end

    test "creates with the requested tier and status" do
      {:ok, org} = ApiKeys.create_org("Fresh Org", tier: "pro", status: "pending")

      assert org.tier == "pro"
      assert org.status == "pending"
    end

    # The tier bug: find_or_create_org returns the existing org unchanged, so a
    # Pro signup reusing a free org's name produced a paid checkout against an
    # org that stayed on the free tier.
    # Guard verification caught this gap: every test above exercises
    # ApiKeys.create_org/2 directly, so swapping the *router* back to
    # find_or_create_org left them all passing. Testing the function is not
    # testing the path that issues credentials -- which is the same mistake
    # that produced the bug in the first place.
    test "POST /signup issues no key when the org name already exists" do
      {:ok, _} = ApiKeys.create_org("Existing Co", tier: "free", status: "active")

      conn =
        conn(:post, "/signup", "name=Existing+Co&tier=free")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ "already taken"

      refute conn.resp_body =~ ~r/lei_[a-f0-9]{32}/,
             "signup handed out an API key for an org the caller does not own"
    end

    test "POST /signup still issues a key for a genuinely new org" do
      conn =
        conn(:post, "/signup", "name=Brand+New+Co&tier=free")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/lei_[a-f0-9]{32}/
    end

    test "find_or_create_org ignores the requested tier for an existing org" do
      {:ok, free_org} = ApiKeys.create_org("Tier Test", tier: "free", status: "active")

      {:ok, same_org} = ApiKeys.find_or_create_org("Tier Test", tier: "pro", status: "active")

      assert same_org.id == free_org.id
      assert same_org.tier == "free", "documents why signup paths must not use this"
    end
  end
end
