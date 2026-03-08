defmodule Lei.RecoveryCodeTest do
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  alias Lei.ApiKeys

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "generate_recovery_code/1" do
    test "generates a recovery code with lei_recover_ prefix" do
      {:ok, org} = ApiKeys.find_or_create_org("Recovery Org", status: "active")
      {:ok, raw_code} = ApiKeys.generate_recovery_code(org)

      assert String.starts_with?(raw_code, "lei_recover_")
      assert String.length(raw_code) == 36
    end

    test "stores only the hash" do
      {:ok, org} = ApiKeys.find_or_create_org("Recovery Hash Org", status: "active")
      {:ok, raw_code} = ApiKeys.generate_recovery_code(org)

      expected_hash = :crypto.hash(:sha256, raw_code) |> Base.encode16(case: :lower)

      rc =
        Lei.Repo.one(
          from(r in Lei.RecoveryCode,
            where: r.org_id == ^org.id,
            order_by: [desc: :inserted_at],
            limit: 1
          )
        )

      assert rc.code_hash == expected_hash
      assert rc.used == false
    end
  end

  describe "recover_with_code/2" do
    test "recovers with valid slug and code" do
      {:ok, org} = ApiKeys.find_or_create_org("Recover Test Org", status: "active")
      {:ok, raw_code} = ApiKeys.generate_recovery_code(org)

      assert {:ok, raw_key, new_recovery_code} = ApiKeys.recover_with_code(org.slug, raw_code)
      assert String.starts_with?(raw_key, "lei_")
      assert String.starts_with?(new_recovery_code, "lei_recover_")
    end

    test "old code is invalidated after recovery" do
      {:ok, org} = ApiKeys.find_or_create_org("Rotate Test Org", status: "active")
      {:ok, raw_code} = ApiKeys.generate_recovery_code(org)

      {:ok, _key, _new_code} = ApiKeys.recover_with_code(org.slug, raw_code)

      # Old code should fail
      assert {:error, :invalid_recovery} = ApiKeys.recover_with_code(org.slug, raw_code)
    end

    test "new recovery code works after rotation" do
      {:ok, org} = ApiKeys.find_or_create_org("Rotate Chain Org", status: "active")
      {:ok, raw_code} = ApiKeys.generate_recovery_code(org)

      {:ok, _key, new_code} = ApiKeys.recover_with_code(org.slug, raw_code)

      # New code should work
      assert {:ok, _key2, _code2} = ApiKeys.recover_with_code(org.slug, new_code)
    end

    test "rejects invalid slug" do
      assert {:error, :invalid_recovery} =
               ApiKeys.recover_with_code("nonexistent", "lei_recover_fake")
    end

    test "rejects invalid code" do
      {:ok, org} = ApiKeys.find_or_create_org("Bad Code Org", status: "active")

      assert {:error, :invalid_recovery} =
               ApiKeys.recover_with_code(org.slug, "lei_recover_invalid_code_000000")
    end
  end
end
