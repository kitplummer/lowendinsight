defmodule Lei.ApiKeysTest do
  use ExUnit.Case, async: false
  alias Lei.ApiKeys

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "find_or_create_org/1" do
    test "creates a new org" do
      {:ok, org} = ApiKeys.find_or_create_org("Test Org")
      assert org.name == "Test Org"
      assert org.slug == "test-org"
      assert org.tier == "free"
    end

    test "returns existing org by slug" do
      {:ok, org1} = ApiKeys.find_or_create_org("Test Org")
      {:ok, org2} = ApiKeys.find_or_create_org("Test Org")
      assert org1.id == org2.id
    end

    test "matches slug case-insensitively" do
      {:ok, org1} = ApiKeys.find_or_create_org("My Org")
      {:ok, org2} = ApiKeys.find_or_create_org("my org")
      assert org1.id == org2.id
    end
  end

  describe "create_api_key/3" do
    test "creates key with lei_ prefix" do
      {:ok, org} = ApiKeys.find_or_create_org("Key Org")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "test-key", ["analyze"])

      assert String.starts_with?(raw_key, "lei_")
      assert String.length(raw_key) == 36
      assert api_key.name == "test-key"
      assert api_key.scopes == ["analyze"]
      assert api_key.active == true
      assert String.length(api_key.key_prefix) == 8
    end

    test "stores hash, not raw key" do
      {:ok, org} = ApiKeys.find_or_create_org("Hash Org")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "hash-key")

      refute api_key.key_hash == raw_key
      expected_hash = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
      assert api_key.key_hash == expected_hash
    end

    test "defaults scopes to empty list" do
      {:ok, org} = ApiKeys.find_or_create_org("Scope Org")
      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "no-scope")
      assert api_key.scopes == []
    end
  end

  describe "authenticate_key/1" do
    test "authenticates valid key" do
      {:ok, org} = ApiKeys.find_or_create_org("Auth Org")
      {:ok, raw_key, _api_key} = ApiKeys.create_api_key(org, "auth-key")

      assert {:ok, found} = ApiKeys.authenticate_key(raw_key)
      assert found.name == "auth-key"
      assert found.org.name == "Auth Org"
    end

    test "rejects invalid key" do
      assert {:error, :invalid_key} = ApiKeys.authenticate_key("lei_bogus")
    end

    test "rejects revoked key" do
      {:ok, org} = ApiKeys.find_or_create_org("Revoke Org")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "revoke-key")
      {:ok, _} = ApiKeys.revoke_key(api_key.id)

      assert {:error, :invalid_key} = ApiKeys.authenticate_key(raw_key)
    end
  end

  describe "list_keys/1" do
    test "lists keys for an org" do
      {:ok, org} = ApiKeys.find_or_create_org("List Org")
      {:ok, _, _} = ApiKeys.create_api_key(org, "key-1")
      {:ok, _, _} = ApiKeys.create_api_key(org, "key-2")

      keys = ApiKeys.list_keys(org)
      assert length(keys) == 2
    end

    test "does not list keys from other orgs" do
      {:ok, org1} = ApiKeys.find_or_create_org("Org A")
      {:ok, org2} = ApiKeys.find_or_create_org("Org B")
      {:ok, _, _} = ApiKeys.create_api_key(org1, "a-key")
      {:ok, _, _} = ApiKeys.create_api_key(org2, "b-key")

      keys = ApiKeys.list_keys(org1)
      assert length(keys) == 1
      assert hd(keys).name == "a-key"
    end
  end

  describe "revoke_key/1" do
    test "sets active to false" do
      {:ok, org} = ApiKeys.find_or_create_org("Revoke Org 2")
      {:ok, _, api_key} = ApiKeys.create_api_key(org, "to-revoke")

      assert {:ok, revoked} = ApiKeys.revoke_key(api_key.id)
      assert revoked.active == false
    end

    test "returns error for non-existent key" do
      assert {:error, :not_found} = ApiKeys.revoke_key(999_999)
    end
  end

  describe "touch_last_used/1" do
    test "updates last_used_at asynchronously" do
      {:ok, org} = ApiKeys.find_or_create_org("Touch Org")
      {:ok, _, api_key} = ApiKeys.create_api_key(org, "touch-key")
      assert api_key.last_used_at == nil

      {:ok, pid} = ApiKeys.touch_last_used(api_key)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      updated = Lei.Repo.get!(Lei.ApiKey, api_key.id)
      assert updated.last_used_at != nil
    end
  end
end
