defmodule LowendinsightGet.ApiKeyTest do
  use ExUnit.Case, async: true

  alias LowendinsightGet.ApiKey

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LowendinsightGet.Repo)
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
      cs =
        ApiKey.changeset(%ApiKey{}, %{
          key_hash: "abc123",
          key_prefix: "lei_a1b2",
          org_id: 1
        })

      refute cs.valid?
      assert {:name, {"can't be blank", _}} = hd(cs.errors)
    end

    test "invalid without key_hash" do
      cs =
        ApiKey.changeset(%ApiKey{}, %{
          name: "ci-key",
          key_prefix: "lei_a1b2",
          org_id: 1
        })

      refute cs.valid?
    end

    test "invalid without org_id" do
      cs =
        ApiKey.changeset(%ApiKey{}, %{
          name: "ci-key",
          key_hash: "abc123",
          key_prefix: "lei_a1b2"
        })

      refute cs.valid?
    end

    test "defaults active to true" do
      key = %ApiKey{}
      assert key.active == true
    end

    test "defaults scopes to empty list" do
      key = %ApiKey{}
      assert key.scopes == []
    end
  end
end
