defmodule Lei.WalletsTest do
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Org, Repo, UsageTracker, Wallets}

  @address "0xAbC1230000000000000000000000000000000001"
  @normalised "0xabc1230000000000000000000000000000000001"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp address(n), do: "0x" <> String.pad_leading(Integer.to_string(n, 16), 40, "0")

  describe "provision/2" do
    test "creates an org for a new wallet" do
      assert {:ok, org} = Wallets.provision(@address)

      assert org.wallet_address == @normalised
      assert org.status == "active"
      assert Wallets.wallet_org?(org)
    end

    test "refuses a wallet that already has an org, and does not return it" do
      {:ok, first} = Wallets.provision(@address)

      # Returning the existing org here is org takeover: a wallet address is
      # public, so anyone can present someone else's. #89 in a new costume.
      assert {:error, :wallet_taken} = Wallets.provision(@address)

      assert Repo.aggregate(Org, :count, :id) == 1
      assert Wallets.find_by_address(@address).id == first.id
    end

    test "treats a checksummed address as the same wallet" do
      {:ok, _} = Wallets.provision(@address)

      # EVM addresses are hex and case-insensitive. Storing them as presented
      # would let one wallet hold two orgs.
      assert {:error, :wallet_taken} = Wallets.provision(String.downcase(@address))

      assert {:error, :wallet_taken} =
               Wallets.provision(String.upcase("0xABC123") <> String.duplicate("0", 33) <> "1")
    end

    test "the race is closed by the database, not a pre-check" do
      # Both tasks see no existing org; only one can win the unique index.
      results =
        1..6
        |> Task.async_stream(fn _ -> Wallets.provision(@address) end, max_concurrency: 6)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :wallet_taken}, &1)) == 5
      assert Repo.aggregate(Org, :count, :id) == 1
    end

    test "rejects anything that is not a 0x hex address" do
      for bad <- ["not-an-address", "0x123", "", "0xZZZ1230000000000000000000000000000000001"] do
        assert {:error, %Ecto.Changeset{}} = Wallets.provision(bad),
               "expected #{inspect(bad)} to be refused"
      end

      assert Repo.aggregate(Org, :count, :id) == 0
    end

    test "distinct wallets get distinct orgs" do
      {:ok, a} = Wallets.provision(address(1))
      {:ok, b} = Wallets.provision(address(2))

      refute a.id == b.id
      assert Repo.aggregate(Org, :count, :id) == 2
    end
  end

  describe "no free tier for agents" do
    test "a wallet org is created with a zero free-tier allowance" do
      {:ok, org} = Wallets.provision(@address)

      assert org.free_tier_analyses_limit == 0
    end

    test "a zero-balance wallet org is refused, not served" do
      {:ok, org} = Wallets.provision(@address)

      assert {:error, :insufficient_credits, %{balance: 0}} =
               UsageTracker.check_free_tier_quota(org.id)
    end

    test "a funded wallet org is served" do
      {:ok, org} = Wallets.provision(@address)
      {:ok, _} = Credits.grant(org.id, 15_000, "purchase:x402", external_ref: "0xtx1")

      assert {:ok, 15_000} = UsageTracker.check_free_tier_quota(org.id)
    end

    test "a wallet org that has spent its balance is refused again" do
      {:ok, org} = Wallets.provision(@address)
      {:ok, _} = Credits.grant(org.id, 50, "purchase:x402", external_ref: "0xtx2")
      {:ok, _key, api_key} = ApiKeys.create_api_key(org, "agent", ["analyze"])

      # One cache miss is 50 credits: exactly the balance.
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 0, 1)

      assert Credits.balance(org.id) == 0

      assert {:error, :insufficient_credits, %{balance: 0}} =
               UsageTracker.check_free_tier_quota(org.id)
    end

    test "the credit gate overrides tier, so a pro wallet org is still refused at zero" do
      # Otherwise setting tier to "pro" would be a way around paying, and tier
      # is not something the wallet holder should be able to influence.
      {:ok, org} = Wallets.provision(@address)
      {:ok, org} = org |> Ecto.Changeset.change(tier: "pro") |> Repo.update()

      assert {:error, :insufficient_credits, _} = UsageTracker.check_free_tier_quota(org.id)
    end
  end

  describe "orgs without a wallet are unaffected" do
    test "several email orgs coexist with null wallet addresses" do
      # The unique index is partial. Without the WHERE clause every org after
      # the first would collide on NULL in some databases, and this is the
      # cheapest way to notice if that changes.
      for n <- 1..3 do
        {:ok, _} = ApiKeys.find_or_create_org("Plain Org #{n}", status: "active")
      end

      assert Repo.aggregate(Org, :count, :id) == 3
    end

    test "a free org still uses the free-tier allowance, not credits" do
      {:ok, org} = ApiKeys.find_or_create_org("Free Org", status: "active")

      refute Wallets.wallet_org?(org)
      assert {:ok, remaining} = UsageTracker.check_free_tier_quota(org.id)
      assert remaining > 0
    end
  end

  describe "find_by_address/1" do
    test "finds regardless of case" do
      {:ok, org} = Wallets.provision(@address)

      assert Wallets.find_by_address(@normalised).id == org.id
      assert Wallets.find_by_address(String.upcase(@normalised)).id == org.id
    end

    test "returns nil for an unknown or nil address" do
      assert Wallets.find_by_address(address(99)) == nil
      assert Wallets.find_by_address(nil) == nil
    end
  end
end
