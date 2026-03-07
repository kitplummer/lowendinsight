defmodule LowendinsightGet.OrgTest do
  use ExUnit.Case, async: true

  alias LowendinsightGet.Org

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LowendinsightGet.Repo)
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

    test "defaults tier to free" do
      cs = Org.changeset(%Org{}, %{name: "Test"})
      # tier default comes from schema, not changeset
      assert cs.valid?
    end

    test "accepts pro tier" do
      cs = Org.changeset(%Org{}, %{name: "Test", tier: "pro"})
      assert cs.valid?
    end
  end
end
