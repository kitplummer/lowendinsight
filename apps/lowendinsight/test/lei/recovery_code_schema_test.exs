defmodule Lei.RecoveryCodeSchemaTest do
  use ExUnit.Case, async: true
  alias Lei.RecoveryCode

  describe "changeset/2" do
    test "valid changeset" do
      attrs = %{org_id: 1, code_hash: "abc123"}
      changeset = RecoveryCode.changeset(%RecoveryCode{}, attrs)
      assert changeset.valid?
    end

    test "requires org_id and code_hash" do
      changeset = RecoveryCode.changeset(%RecoveryCode{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert :org_id in Map.keys(errors)
      assert :code_hash in Map.keys(errors)
    end

    test "defaults used to false" do
      attrs = %{org_id: 1, code_hash: "abc123"}
      changeset = RecoveryCode.changeset(%RecoveryCode{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :used) == false
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
