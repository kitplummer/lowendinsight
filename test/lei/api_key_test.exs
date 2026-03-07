defmodule Lei.ApiKeyTest do
  use ExUnit.Case, async: true
  alias Lei.ApiKey

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
  end

  describe "changeset/2" do
    test "valid with required fields" do
      cs =
        ApiKey.changeset(%ApiKey{}, %{
          name: "ci-key",
          key_hash: "abc123",
          key_prefix: "lei_a1b2",
          org_id: 1
        })

      assert cs.valid?
    end

    test "invalid without name" do
      cs = ApiKey.changeset(%ApiKey{}, %{key_hash: "abc", key_prefix: "lei_", org_id: 1})
      refute cs.valid?
    end

    test "invalid without key_hash" do
      cs = ApiKey.changeset(%ApiKey{}, %{name: "k", key_prefix: "lei_", org_id: 1})
      refute cs.valid?
    end

    test "invalid without org_id" do
      cs = ApiKey.changeset(%ApiKey{}, %{name: "k", key_hash: "abc", key_prefix: "lei_"})
      refute cs.valid?
    end

    test "defaults active to true" do
      assert %ApiKey{}.active == true
    end

    test "defaults scopes to empty list" do
      assert %ApiKey{}.scopes == []
    end
  end
end
