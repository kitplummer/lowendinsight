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

  alias Lei.{ApiKeys, Repo}

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
    test "find_or_create_org ignores the requested tier for an existing org" do
      {:ok, free_org} = ApiKeys.create_org("Tier Test", tier: "free", status: "active")

      {:ok, same_org} = ApiKeys.find_or_create_org("Tier Test", tier: "pro", status: "active")

      assert same_org.id == free_org.id
      assert same_org.tier == "free", "documents why signup paths must not use this"
    end
  end
end
