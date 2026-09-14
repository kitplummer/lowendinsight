defmodule Lei.Stripe.ObjectCheckTest do
  @moduledoc """
  Price IDs carry no mode, so the only way to know a price belongs to the key's
  mode is to ask Stripe for it with that key (#137).
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.Stripe.ObjectCheck

  @live "sk_live_" <> String.duplicate("x", 24)
  @test_key "sk_test_" <> String.duplicate("x", 24)
  @prices ["price_pro", "price_metered"]

  setup :set_mox_global
  setup :verify_on_exit!

  defp price(active \\ true), do: %{"id" => "price_x", "active" => active}
  defp missing, do: {404, %{"error" => %{"code" => "resource_missing"}}}

  describe "check/4" do
    test "every price retrieved and active is ok" do
      expect(Lei.StripeMock, :retrieve_price, 2, fn _ -> {:ok, price()} end)
      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "ok"
    end

    test "asks for each configured price, with nothing skipped" do
      test_pid = self()

      expect(Lei.StripeMock, :retrieve_price, 2, fn id ->
        send(test_pid, {:asked, id})
        {:ok, price()}
      end)

      ObjectCheck.check(@test_key, @prices, nil, Lei.StripeMock)
      assert_received {:asked, "price_pro"}
      assert_received {:asked, "price_metered"}
    end

    test "a price that does not exist for this key is a mismatch -- the half-flip" do
      expect(Lei.StripeMock, :retrieve_price, 2, fn
        "price_pro" -> {:ok, price()}
        "price_metered" -> {:error, missing()}
      end)

      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "mismatch"
    end

    test "an archived price is inactive" do
      expect(Lei.StripeMock, :retrieve_price, 2, fn _ -> {:ok, price(false)} end)
      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "inactive"
    end

    test "a rejected key is unauthorized, whether expired (401) or restricted (403)" do
      for status <- [401, 403] do
        expect(Lei.StripeMock, :retrieve_price, 2, fn _ ->
          {:error, {status, %{"error" => %{"type" => "invalid_request_error"}}}}
        end)

        assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "unauthorized"
      end
    end

    test "a network failure or a server error is unreachable, not a mismatch" do
      expect(Lei.StripeMock, :retrieve_price, 2, fn _ ->
        {:error, %HTTPoison.Error{reason: :timeout}}
      end)

      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "unreachable"

      expect(Lei.StripeMock, :retrieve_price, 2, fn _ -> {:error, {500, %{"raw" => "<html>"}}} end)

      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "unreachable"
    end

    test "the most actionable failure wins when prices disagree" do
      expect(Lei.StripeMock, :retrieve_price, 2, fn
        "price_pro" -> {:error, %HTTPoison.Error{reason: :timeout}}
        "price_metered" -> {:error, missing()}
      end)

      assert ObjectCheck.check(@live, @prices, "production", Lei.StripeMock) == "mismatch"
    end

    test "production with no key, or a key and no prices, is unconfigured and asks nothing" do
      assert ObjectCheck.check(nil, @prices, "production", Lei.StripeMock) == "unconfigured"
      assert ObjectCheck.check(@live, [nil, ""], "production", Lei.StripeMock) == "unconfigured"
    end

    test "outside production, nothing configured is ok and asks nothing" do
      assert ObjectCheck.check(nil, [nil, nil], nil, Lei.StripeMock) == "ok"
      assert ObjectCheck.check(@test_key, [], "staging", Lei.StripeMock) == "ok"
    end

    test "a malformed key is never ok" do
      assert ObjectCheck.check("pk_live_abc", @prices, "production", Lei.StripeMock) ==
               "malformed"

      assert ObjectCheck.check("pk_live_abc", @prices, nil, Lei.StripeMock) == "malformed"
    end
  end

  describe "check_deposit_address/4" do
    @address "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"

    test "an address the key's account holds is ok" do
      expect(Lei.StripeMock, :list_deposit_addresses, fn "tempo" -> {:ok, [@address]} end)
      assert ObjectCheck.check_deposit_address(@test_key, @address, nil, Lei.StripeMock) == "ok"
    end

    test "an address from the other mode is a mismatch" do
      # Deposit addresses carry no mode. A sandbox address beside a live key
      # would take mainnet money Stripe never credits.
      expect(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:ok, ["0xother"]} end)

      assert ObjectCheck.check_deposit_address(@live, @address, "production", Lei.StripeMock) ==
               "mismatch"
    end

    test "comparison ignores hex case" do
      expect(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:ok, [@address]} end)

      assert ObjectCheck.check_deposit_address(
               @live,
               String.upcase(@address) |> String.replace("0X", "0x"),
               "production",
               Lei.StripeMock
             ) == "ok"
    end

    test "rejected key and unreachable Stripe are reported as such" do
      expect(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:error, {401, %{}}} end)

      assert ObjectCheck.check_deposit_address(@live, @address, nil, Lei.StripeMock) ==
               "unauthorized"

      expect(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:error, :timeout} end)

      assert ObjectCheck.check_deposit_address(@live, @address, nil, Lei.StripeMock) ==
               "unreachable"
    end

    test "no address configured asks nothing and is ok" do
      assert ObjectCheck.check_deposit_address(@live, nil, "production", Lei.StripeMock) == "ok"
    end
  end

  describe "the checker process" do
    defp start(config, opts \\ []) do
      name = :"object_check_#{System.unique_integer([:positive])}"

      start_supervised!(
        {ObjectCheck, [name: name, config: fn -> config end] ++ opts},
        id: name
      )

      name
    end

    defp eventually(name, expected, tries \\ 50) do
      case ObjectCheck.status(name) do
        ^expected -> expected
        other when tries == 0 -> other
        _ -> Process.sleep(20) && eventually(name, expected, tries - 1)
      end
    end

    test "reports the result of its first check" do
      stub(Lei.StripeMock, :retrieve_price, fn _ -> {:error, missing()} end)
      name = start({@live, @prices, "production", Lei.StripeMock, nil})
      assert eventually(name, "mismatch") == "mismatch"
    end

    test "retries soon after unreachable, and recovers" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(Lei.StripeMock, :retrieve_price, fn _ ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})
        if n < 2, do: {:error, %HTTPoison.Error{reason: :econnrefused}}, else: {:ok, price()}
      end)

      name =
        start({@live, @prices, "production", Lei.StripeMock, nil},
          retry_ms: 10,
          recheck_ms: 60_000
        )

      assert eventually(name, "ok") == "ok"
    end

    test "a raising Stripe client reads as unreachable, not a crashed checker" do
      stub(Lei.StripeMock, :retrieve_price, fn _ -> raise "boom" end)
      name = start({@live, @prices, "production", Lei.StripeMock, nil}, retry_ms: 60_000)
      assert eventually(name, "unreachable") == "unreachable"
    end

    test "confirms only the address Stripe listed, and only once it has" do
      address = "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
      stub(Lei.StripeMock, :retrieve_price, fn _ -> {:ok, price()} end)
      stub(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:ok, [address]} end)

      name = start({@live, @prices, "production", Lei.StripeMock, address})
      assert eventually(name, "ok") == "ok"

      assert ObjectCheck.deposit_address_confirmed?(address, name)
      refute ObjectCheck.deposit_address_confirmed?("0x" <> String.duplicate("0", 40), name)
    end

    test "an unlisted address is not confirmed and degrades readiness" do
      address = "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
      stub(Lei.StripeMock, :retrieve_price, fn _ -> {:ok, price()} end)
      stub(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:ok, []} end)

      name = start({@live, @prices, "production", Lei.StripeMock, address})
      assert eventually(name, "mismatch") == "mismatch"
      refute ObjectCheck.deposit_address_confirmed?(address, name)
    end

    test "nothing is confirmed by a checker that is not running" do
      refute ObjectCheck.deposit_address_confirmed?("0xabc", :no_such_checker)
    end

    test "status of a checker that is not running is reported, not raised" do
      assert ObjectCheck.status(:no_such_checker) == "not_running"
    end
  end

  test "the application's checker is registered as a readiness check" do
    checks = Application.get_env(:lowendinsight, :optional_health_checks)
    assert checks[:stripe] == {ObjectCheck, :status, []}
    # And it is actually running, so the check reports something real.
    assert is_pid(Process.whereis(ObjectCheck))
  end
end
