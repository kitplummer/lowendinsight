defmodule Lei.OrgStatusTest do
  use ExUnit.Case, async: false
  alias Lei.ApiKeys

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "org status in find_or_create_org/2" do
    test "creates org with specified status" do
      {:ok, org} = ApiKeys.find_or_create_org("Pending Org", status: "pending")
      assert org.status == "pending"
    end

    test "creates active org when status: active" do
      {:ok, org} = ApiKeys.find_or_create_org("Active Org", status: "active")
      assert org.status == "active"
    end

    test "creates org with specified tier" do
      {:ok, org} = ApiKeys.find_or_create_org("Pro Org", tier: "pro", status: "active")
      assert org.tier == "pro"
    end

    test "defaults to pending status" do
      {:ok, org} = ApiKeys.find_or_create_org("Default Status Org")
      assert org.status == "pending"
    end
  end

  describe "activate_org/1" do
    test "sets status to active" do
      {:ok, org} = ApiKeys.find_or_create_org("Activate Org", status: "pending")
      assert org.status == "pending"

      {:ok, activated} = ApiKeys.activate_org(org)
      assert activated.status == "active"
    end
  end

  describe "authenticate_key with org status" do
    test "allows active org" do
      {:ok, org} = ApiKeys.find_or_create_org("Active Auth Org", status: "active")
      {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "test-key", ["analyze"])

      assert {:ok, _api_key} = ApiKeys.authenticate_key(raw_key)
    end

    test "rejects pending org" do
      {:ok, org} = ApiKeys.find_or_create_org("Pending Auth Org", status: "pending")
      {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "test-key", ["analyze"])

      assert {:error, {:org_not_active, "pending"}} = ApiKeys.authenticate_key(raw_key)
    end

    test "rejects suspended org" do
      {:ok, org} = ApiKeys.find_or_create_org("Suspended Auth Org", status: "active")
      {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "test-key", ["analyze"])

      # Suspend the org
      org |> Ecto.Changeset.change(%{status: "suspended"}) |> Lei.Repo.update!()

      assert {:error, {:org_not_active, "suspended"}} = ApiKeys.authenticate_key(raw_key)
    end
  end
end
