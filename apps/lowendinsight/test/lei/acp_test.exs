defmodule Lei.AcpTest do
  use ExUnit.Case, async: false
  alias Lei.Acp

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "create_session/1" do
    test "creates free session" do
      assert {:ok, session} = Acp.create_session("lei-free")
      assert String.starts_with?(session.id, "acp_cs_")
      assert session.sku == "lei-free"
      assert session.amount_cents == 0
      assert session.status == "open"
    end

    test "creates pro session" do
      assert {:ok, session} = Acp.create_session("lei-pro-monthly")
      assert session.sku == "lei-pro-monthly"
      assert session.amount_cents == 2900
    end

    test "rejects invalid SKU" do
      assert {:error, :invalid_sku} = Acp.create_session("invalid-sku")
    end
  end

  describe "update_session/2" do
    test "updates customer name" do
      {:ok, session} = Acp.create_session("lei-free")

      assert {:ok, updated} =
               Acp.update_session(session.id, %{customer_name: "Agent Corp"})

      assert updated.customer_name == "Agent Corp"
    end

    test "rejects update on non-existent session" do
      assert {:error, :not_found} =
               Acp.update_session("acp_cs_nonexistent", %{customer_name: "Test"})
    end
  end

  describe "complete_session/2" do
    test "completes free session with org and key" do
      {:ok, session} = Acp.create_session("lei-free")
      Acp.update_session(session.id, %{customer_name: "Free Agent"})

      assert {:ok, result} = Acp.complete_session(session.id, %{})
      assert String.starts_with?(result.api_key, "lei_")
      assert String.starts_with?(result.recovery_code, "lei_recover_")
      assert result.tier == "free"
      assert result.org_slug != nil
    end

    test "rejects completion of non-existent session" do
      assert {:error, :not_found} = Acp.complete_session("acp_cs_nonexistent", %{})
    end

    test "rejects double completion" do
      {:ok, session} = Acp.create_session("lei-free")
      {:ok, _result} = Acp.complete_session(session.id, %{})
      assert {:error, :session_not_open} = Acp.complete_session(session.id, %{})
    end
  end

  describe "cancel_session/1" do
    test "cancels open session" do
      {:ok, session} = Acp.create_session("lei-free")
      assert {:ok, cancelled} = Acp.cancel_session(session.id)
      assert cancelled.status == "cancelled"
    end

    test "rejects cancel of already cancelled session" do
      {:ok, session} = Acp.create_session("lei-free")
      {:ok, _} = Acp.cancel_session(session.id)
      assert {:error, :session_not_open} = Acp.cancel_session(session.id)
    end

    test "rejects cancel of non-existent session" do
      assert {:error, :not_found} = Acp.cancel_session("acp_cs_nonexistent")
    end
  end

  describe "session expiry" do
    test "rejects completion of expired session" do
      {:ok, session} = Acp.create_session("lei-free")

      # Manually expire it
      session
      |> Ecto.Changeset.change(%{expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
      |> Lei.Repo.update!()

      assert {:error, :session_expired} = Acp.complete_session(session.id, %{})
    end
  end
end
