defmodule Lei.AcpCheckoutSessionTest do
  use ExUnit.Case, async: false
  alias Lei.AcpCheckoutSession

  describe "valid_skus/0" do
    test "returns list of valid SKUs" do
      skus = AcpCheckoutSession.valid_skus()
      assert "lei-free" in skus
      assert "lei-pro-monthly" in skus
    end
  end

  describe "amount_for_sku/1" do
    test "returns 0 for free SKU" do
      assert AcpCheckoutSession.amount_for_sku("lei-free") == 0
    end

    test "returns 2900 for pro SKU" do
      assert AcpCheckoutSession.amount_for_sku("lei-pro-monthly") == 2900
    end

    test "returns nil for invalid SKU" do
      assert AcpCheckoutSession.amount_for_sku("invalid") == nil
    end
  end

  describe "changeset/2" do
    test "valid changeset" do
      attrs = %{
        id: "acp_cs_test",
        sku: "lei-free",
        amount_cents: 0,
        expires_at: DateTime.utc_now()
      }

      changeset = AcpCheckoutSession.changeset(%AcpCheckoutSession{}, attrs)
      assert changeset.valid?
    end

    test "requires id, sku, amount_cents, expires_at" do
      changeset = AcpCheckoutSession.changeset(%AcpCheckoutSession{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert :id in Map.keys(errors)
      assert :sku in Map.keys(errors)
      assert :amount_cents in Map.keys(errors)
      assert :expires_at in Map.keys(errors)
    end

    test "rejects invalid status" do
      attrs = %{
        id: "acp_cs_test",
        sku: "lei-free",
        amount_cents: 0,
        expires_at: DateTime.utc_now(),
        status: "invalid"
      }

      changeset = AcpCheckoutSession.changeset(%AcpCheckoutSession{}, attrs)
      refute changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
