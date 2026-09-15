defmodule Lei.Payments.Rails.TempoTest do
  use ExUnit.Case, async: false

  import Mox

  alias Lei.Payments
  alias Lei.Payments.Mpp.{Challenge, Credential}
  alias Lei.Payments.Rails.Tempo

  setup :verify_on_exit!

  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
  @memo "0xc09702f8182f5d94a23d75cc4c2e9835510fde10de3f5e6f20f2387b799f1ef0"
  @hash "0xcc03711d01ade07b5b546263d81bbe620a32ac12fe540736e5d5f2780c152cf6"

  setup do
    saved =
      for k <- [:stripe_secret_key, :tempo_deposit_address],
          do: {k, Application.get_env(:lei_service, k)}

    Application.put_env(
      :lei_service,
      :stripe_secret_key,
      "sk_test_" <> String.duplicate("x", 24)
    )

    Application.put_env(:lei_service, :tempo_deposit_address, @deposit)

    on_exit(fn ->
      for {k, v} <- saved,
          do:
            if(v,
              do: Application.put_env(:lei_service, k, v),
              else: Application.delete_env(:lei_service, k)
            )
    end)

    :ok
  end

  defp confirmed, do: [confirmed?: fn _ -> true end]

  # The real testnet transfer: 0.50 pathUSD carrying @memo. One credit is
  # $0.001, so 500 credits is $0.50, the smallest purchase Stripe will verify.
  #
  # opts first: Keyword.get takes the first match, and a default placed ahead
  # of an override silently wins -- which made the stolen-hash test below fail
  # for the wrong reason on its first run.
  defp issue(credits \\ 500, opts \\ []) do
    {:ok, challenge} =
      Tempo.requirements(
        credits,
        opts ++ [realm: "lowendinsight.dev", memo: @memo] ++ confirmed()
      )

    challenge
  end

  defp credential_for(challenge, payload \\ %{"type" => "hash", "hash" => @hash}) do
    echoed = %{
      "id" => challenge.id,
      "realm" => challenge.realm,
      "method" => challenge.method,
      "intent" => challenge.intent,
      "request" => Challenge.encode_json(challenge.request)
    }

    %Credential{challenge: echoed, payload: payload, source: "did:pkh:eip155:42431:0xpayer"}
  end

  defp receipt(name \\ "memo_to_deposit") do
    Path.join([__DIR__, "..", "..", "fixtures", "tempo", "#{name}.json"])
    |> File.read!()
    |> Poison.decode!()
  end

  defp intent(status, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "pi_tempo_1",
        "status" => status,
        "amount_received" => if(status == "succeeded", do: 50, else: 0),
        "latest_charge" => %{
          "payment_method_details" => %{
            "crypto" => %{
              "buyer_address" => "0x95b01240addf561daa31b76b1e8f89f8c4287917",
              "network" => "tempo",
              "token_currency" => "usdc",
              "transaction_hash" => @hash
            }
          }
        }
      },
      extra
    )
  end

  defp fast, do: [poll_interval_ms: 0, settle_timeout_ms: 1_000]

  describe "the rail declares itself honestly" do
    test "passes boot validation and the ledger accepts its name" do
      assert :ok = Payments.validate_rails!([Tempo])
      assert Tempo.name() in Payments.known_rails()
    end

    test "states Stripe's observed $0.50 minimum" do
      assert Tempo.minimum_purchase_credits() == 500
      assert {:error, {:below_minimum_chargeable, 499}} = Tempo.requirements(499, confirmed())
    end
  end

  describe "the challenge" do
    test "asks for the exact token amount, to our address, with a memo and push only" do
      challenge = issue(15_000)

      assert challenge.method == "tempo"
      assert challenge.intent == "charge"
      # $15.00 is 15,000,000 units of a 6-decimal token.
      assert challenge.request["amount"] == "15000000"
      assert challenge.request["currency"] == "0x20c0000000000000000000000000000000000000"
      assert challenge.request["recipient"] == @deposit
      assert challenge.request["credits"] == 15_000

      assert challenge.request["methodDetails"] == %{
               "chainId" => 42431,
               "memo" => @memo,
               "supportedModes" => ["push"]
             }
    end

    test "every challenge gets its own random memo" do
      {:ok, a} = Tempo.requirements(500, confirmed())
      {:ok, b} = Tempo.requirements(500, confirmed())
      memo = get_in(a.request, ["methodDetails", "memo"])

      assert memo =~ ~r/\A0x[0-9a-f]{64}\z/
      refute memo == get_in(b.request, ["methodDetails", "memo"])
    end

    test "no challenge names an address Stripe has not confirmed" do
      # Mainnet money sent to an address Stripe will not credit is gone.
      assert {:error, {:unavailable, :deposit_address_unconfirmed}} =
               Tempo.requirements(500, confirmed?: fn _ -> false end)
    end

    test "by default, confirmation comes from the object checker, which has confirmed nothing here" do
      assert {:error, {:unavailable, :deposit_address_unconfirmed}} = Tempo.requirements(500)
    end

    test "no address, or no Stripe key, is unavailable rather than an error" do
      Application.delete_env(:lei_service, :tempo_deposit_address)

      assert {:error, {:unavailable, :no_deposit_address}} =
               Tempo.requirements(500, confirmed())

      Application.delete_env(:lei_service, :stripe_secret_key)

      assert {:error, {:unavailable, :stripe_not_configured}} =
               Tempo.requirements(500, confirmed())
    end

    test "a live key means mainnet and USDC.e" do
      Application.put_env(
        :lei_service,
        :stripe_secret_key,
        "sk_live_" <> String.duplicate("x", 24)
      )

      {:ok, challenge} = Tempo.requirements(500, confirmed())

      assert get_in(challenge.request, ["methodDetails", "chainId"]) == 4217
      assert challenge.request["currency"] == "0x20c000000000000000000000b9537d11c60e8b50"
    end
  end

  describe "verifying a payment" do
    test "a bound transfer that Stripe settles is credited" do
      challenge = issue()

      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn url, hash ->
        assert url == "https://rpc.moderato.tempo.xyz"
        assert hash == @hash
        {:ok, receipt()}
      end)

      expect(Lei.StripeMock, :create_crypto_verification_intent, fn params ->
        assert params.amount == 50
        assert params.network == "tempo"
        assert params.transaction_hash == @hash
        assert params.idempotency_key == "tempo_#{@hash}"
        {:ok, intent("processing", %{"latest_charge" => nil})}
      end)

      expect(Lei.StripeMock, :retrieve_payment_intent, fn "pi_tempo_1" ->
        {:ok, intent("succeeded")}
      end)

      assert {:ok, settlement} =
               Tempo.verify(credential_for(challenge), [challenge: challenge] ++ fast())

      assert settlement.credits == 500
      assert settlement.rail == "tempo"
      assert settlement.settlement_ref == "pi_tempo_1"
      assert settlement.usd_value_cents == 50
      assert settlement.asset == "USDC"
      assert settlement.amount == "0.500000"
      assert settlement.payer == "0x95b01240addf561daa31b76b1e8f89f8c4287917"
    end

    test "processing is polled until it settles" do
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
        {:ok, intent("processing")}
      end)

      expect(Lei.StripeMock, :retrieve_payment_intent, 3, fn _ ->
        n = Process.get(:polls, 0)
        Process.put(:polls, n + 1)
        {:ok, if(n < 2, do: intent("processing"), else: intent("succeeded"))}
      end)

      assert {:ok, _} = Tempo.verify(credential_for(challenge), [challenge: challenge] ++ fast())
    end

    test "still processing at the deadline is not credited" do
      # Not a refusal of the payment: the agent retries the same credential and
      # the idempotency key brings it back to the same intent.
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
        {:ok, intent("processing")}
      end)

      stub(Lei.StripeMock, :retrieve_payment_intent, fn _ -> {:ok, intent("processing")} end)

      assert {:error, {:payment_not_settled, "processing"}} =
               Tempo.verify(
                 credential_for(challenge),
                 challenge: challenge,
                 poll_interval_ms: 5,
                 settle_timeout_ms: 30
               )
    end

    test "a transfer Stripe already tracks under another intent is refused, not adopted" do
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      # The response sandbox Stripe gave for a second verification of one
      # transfer, trimmed.
      expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
        {:error,
         {400,
          %{
            "error" => %{
              "code" => "resource_already_exists",
              "message" => "PaymentIntent `pi_3UFNcY` is already tracking this transaction."
            }
          }}}
      end)

      assert {:error, :transaction_already_verified} =
               Tempo.verify(credential_for(challenge), [challenge: challenge] ++ fast())
    end

    test "a Stripe decline is refused with its reason" do
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      expect(Lei.StripeMock, :create_crypto_verification_intent, fn _ ->
        {:ok,
         intent("requires_payment_method", %{
           "last_payment_error" => %{"decline_code" => "invalid_amount"}
         })}
      end)

      assert {:error, {:payment_declined, "invalid_amount"}} =
               Tempo.verify(credential_for(challenge), [challenge: challenge] ++ fast())
    end
  end

  describe "refusals before Stripe is asked" do
    # Mox fails these if Stripe is called: nothing is created at Stripe for a
    # credential that does not bind to its challenge.

    test "a real payment to us, for a different challenge -- the stolen hash" do
      challenge = issue(500, memo: "0x" <> String.duplicate("22", 32))
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      assert {:error, {:transfer_not_bound, :no_matching_transfer}} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "a transfer with no memo" do
      challenge = issue()

      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ ->
        {:ok, receipt("nomemo_to_deposit")}
      end)

      assert {:error, {:transfer_not_bound, :no_matching_transfer}} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "a transfer to someone else" do
      challenge = issue()

      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ ->
        {:ok, receipt("to_other_address")}
      end)

      assert {:error, {:transfer_not_bound, _}} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "an amount other than the one asked, over or under" do
      # 0.50 was sent. Stripe declines a mismatch, so accepting an overpayment
      # would pass here and fail there with the money already gone.
      over = issue(500)
      under_challenge = issue(1_000)

      stub(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, receipt()} end)

      assert {:error, {:transfer_not_bound, :underpaid}} =
               Tempo.verify(credential_for(under_challenge), challenge: under_challenge)

      bigger =
        put_in(
          receipt()["logs"],
          Enum.map(receipt()["logs"], fn log ->
            if hd(log["topics"]) == Lei.Tempo.Transfer.transfer_with_memo_topic(),
              do:
                Map.put(
                  log,
                  "data",
                  "0x" <> String.pad_leading(Integer.to_string(600_000, 16), 64, "0")
                ),
              else: log
          end)
        )

      stub(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:ok, bigger} end)

      assert {:error, :amount_mismatch} = Tempo.verify(credential_for(over), challenge: over)
    end

    test "a transaction the chain does not know" do
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:error, :not_found} end)

      assert {:error, :transaction_not_found} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "the chain unreachable" do
      challenge = issue()
      expect(Lei.TempoRpcMock, :get_transaction_receipt, fn _, _ -> {:error, :timeout} end)

      assert {:error, {:chain_unreachable, :timeout}} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "a challenge issued on one network answered after a mode switch" do
      challenge = issue()

      Application.put_env(
        :lei_service,
        :stripe_secret_key,
        "sk_live_" <> String.duplicate("x", 24)
      )

      assert {:error, :network_changed} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end

    test "pull-mode and malformed credentials" do
      challenge = issue()

      assert {:error, {:unsupported_credential_type, "transaction"}} =
               Tempo.verify(
                 credential_for(challenge, %{"type" => "transaction", "signature" => "0x00"}),
                 challenge: challenge
               )

      assert {:error, :no_transaction_hash} =
               Tempo.verify(credential_for(challenge, %{"type" => "hash", "hash" => "0x1234"}),
                 challenge: challenge
               )
    end

    test "a credential for a challenge we did not issue" do
      assert {:error, :challenge_mismatch} =
               Tempo.verify(credential_for(issue(500)), challenge: issue(15_000))
    end

    test "an expired challenge" do
      challenge = issue(500, expires: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:error, :challenge_expired} =
               Tempo.verify(credential_for(challenge), challenge: challenge)
    end
  end
end
