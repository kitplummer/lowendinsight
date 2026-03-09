defmodule Lei.OrgTest do
  use ExUnit.Case, async: true
  alias Lei.Org

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
  end

  describe "changeset/2" do
    test "valid with name" do
      cs = Org.changeset(%Org{}, %{name: "My Org"})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "my-org"
    end

    test "generates slug from name with special characters" do
      cs = Org.changeset(%Org{}, %{name: "Hello World!! 123"})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :slug) == "hello-world-123"
    end

    test "trims leading and trailing dashes from slug" do
      cs = Org.changeset(%Org{}, %{name: "---test---"})
      assert Ecto.Changeset.get_change(cs, :slug) == "test"
    end

    test "invalid without name" do
      cs = Org.changeset(%Org{}, %{})
      refute cs.valid?
      assert {:name, {"can't be blank", _}} = hd(cs.errors)
    end

    test "invalid with bad tier" do
      cs = Org.changeset(%Org{}, %{name: "Test", tier: "enterprise"})
      refute cs.valid?
      assert {:tier, _} = List.keyfind(cs.errors, :tier, 0)
    end

    test "accepts pro tier" do
      cs = Org.changeset(%Org{}, %{name: "Test", tier: "pro"})
      assert cs.valid?
    end

    test "accepts valid status" do
      for status <- ~w(pending active suspended) do
        cs = Org.changeset(%Org{}, %{name: "Test", status: status})
        assert cs.valid?, "Expected status #{status} to be valid"
      end
    end

    test "rejects invalid status" do
      cs = Org.changeset(%Org{}, %{name: "Test", status: "deleted"})
      refute cs.valid?
    end
  end

  describe "activate_changeset/1" do
    test "sets status to active" do
      org = %Org{status: "pending"}
      cs = Org.activate_changeset(org)
      assert Ecto.Changeset.get_change(cs, :status) == "active"
    end
  end

  describe "stripe_changeset/2" do
    test "sets stripe fields" do
      org = %Org{}

      cs =
        Org.stripe_changeset(org, %{
          stripe_customer_id: "cus_123",
          stripe_subscription_id: "sub_456",
          status: "active"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :stripe_customer_id) == "cus_123"
      assert Ecto.Changeset.get_change(cs, :stripe_subscription_id) == "sub_456"
    end
  end
end
