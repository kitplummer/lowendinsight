defmodule Lei.Payments.Rails.MppTest do
  use ExUnit.Case, async: false

  import Mox

  alias Lei.Payments
  alias Lei.Payments.Mpp.{Challenge, Credential}
  alias Lei.Payments.Rails.Mpp

  setup :verify_on_exit!

  defp issue(credits \\ 15_000) do
    {:ok, challenge} = Mpp.requirements(credits, realm: "lowendinsight.dev")
    challenge
  end

  defp credential_for(challenge, overrides \\ %{}) do
    echoed =
      %{
        "id" => challenge.id,
        "realm" => challenge.realm,
        "method" => challenge.method,
        "intent" => challenge.intent,
        "request" => Challenge.encode_json(challenge.request)
      }
      |> Map.merge(overrides)

    %Credential{challenge: echoed, payload: %{"spt" => "spt_test_123"}, source: "acct_agent"}
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "pi_3ABC",
        "status" => "succeeded",
        "amount" => 1500,
        "amount_received" => 1500,
        "currency" => "usd"
      },
      overrides
    )
  end

  describe "the rail declares itself honestly" do
    test "passes boot validation" do
      assert :ok = Payments.validate_rails!([Mpp])
    end

    test "declares only the cadence it implements" do
      # MPP can stream, and on Tempo it would be affordable. It is not declared
      # because there is no code path that settles repeatedly against one
      # authorisation -- a cadence a rail announces but cannot perform passes
      # the boot check and fails an agent.
      assert Mpp.cadences() == [:one_shot]
    end

    test "states no minimum purchase" do
      assert Mpp.minimum_purchase_credits() == nil
    end

    test "its name is one the ledger will accept" do
      assert Mpp.name() in Payments.known_rails()
    end
  end

  describe "pricing" do
    test "credits convert to cents at the ADR-001 rate" do
      # One credit is $0.001. 15,000 credits is $15.00.
      assert Mpp.cents_for(15_000) == 1500
      assert Mpp.cents_for(10) == 1
    end

    test "the challenge charges exactly what the conversion says" do
      challenge = issue(15_000)

      assert challenge.request["amount"] == "1500"
      assert challenge.request["credits"] == 15_000
      assert challenge.request["currency"] == "usd"
    end

    test "the challenge names our Stripe profile, which SPTs are scoped to" do
      # An agent's wallet mints a token for a specific seller profile, and the
      # challenge is where it learns which. Without it no real client can
      # produce a token this rail can charge (#143).
      challenge = issue()

      assert challenge.request["methodDetails"] == %{
               "networkId" => "profile_test_lei",
               "paymentMethodTypes" => ["card", "link"]
             }
    end

    test "no challenge is issued without a Stripe profile" do
      # A challenge no client can answer is a 402 that looks payable and is not.
      previous = Application.get_env(:lowendinsight, :stripe_profile_id)
      Application.delete_env(:lowendinsight, :stripe_profile_id)
      on_exit(fn -> Application.put_env(:lowendinsight, :stripe_profile_id, previous) end)

      assert {:error, :no_stripe_profile} = Mpp.requirements(15_000)
    end

    test "a purchase too small to charge is refused rather than charged zero" do
      # Below a cent there is nothing a network can take, and a zero-amount
      # intent would settle for nothing and read as success.
      assert {:error, {:below_minimum_chargeable, 5}} = Mpp.requirements(5)
    end

    test "the challenge expires" do
      challenge = issue()

      refute is_nil(challenge.expires)
      refute Challenge.expired?(challenge)
    end
  end

  describe "verifying a payment" do
    test "a good credential settles" do
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn params ->
        assert params.amount == 1500
        assert params.currency == "usd"
        # The token travels as a token. #131 passed it as payment_method, which
        # Stripe answers with "No such PaymentMethod" -- and this test asserted
        # exactly that call, so it passed (#143).
        assert params.spt == "spt_test_123"
        refute Map.has_key?(params, :payment_method)
        {:ok, intent()}
      end)

      assert {:ok, settlement} =
               Mpp.verify(credential_for(challenge), challenge: challenge)

      assert settlement.credits == 15_000
      assert settlement.rail == "mpp"
      assert settlement.settlement_ref == "pi_3ABC"
      assert settlement.usd_value_cents == 1500
      assert settlement.asset == "USD"
      assert settlement.amount == "15.00"
      assert settlement.payer == "acct_agent"
    end

    test "the charge is idempotent per challenge and token" do
      # A retry after a timeout must reach the PaymentIntent that already took
      # the money. Without a key, Stripe creates a second one -- and an SPT is
      # single-use, so that second attempt is refused as "deactivated" and the
      # agent that paid is turned away. Observed against sandbox Stripe (#143).
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, 2, fn params ->
        assert params.idempotency_key == "mpp_#{challenge.id}_spt_test_123"
        {:ok, intent()}
      end)

      assert {:ok, _} = Mpp.verify(credential_for(challenge), challenge: challenge)
      assert {:ok, _} = Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "the settlement reference is Stripe's, not ours" do
      # It becomes credit_entries.external_ref. Two of ours could name one
      # settlement, and the replay defence would not hold.
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:ok, intent(%{"id" => "pi_9XYZ"})}
      end)

      assert {:ok, %{settlement_ref: "pi_9XYZ"}} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "the settlement is creditable through the boundary" do
      # The point of the shape: a rail hands its settlement straight to
      # Lei.Payments.credit_settlement/2 without the caller restating anything.
      challenge = issue()
      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ -> {:ok, intent()} end)

      {:ok, settlement} = Mpp.verify(credential_for(challenge), challenge: challenge)

      assert Map.has_key?(settlement, :rail)
      assert Map.has_key?(settlement, :credits)
      assert Map.has_key?(settlement, :settlement_ref)
    end
  end

  describe "refusals" do
    test "a credential for a challenge we did not issue" do
      # Cross-resource substitution: buy something cheap, spend the proof on
      # something dear. No PaymentIntent is created at all.
      cheap = issue(100)
      dear = issue(15_000)

      assert {:error, :challenge_mismatch} =
               Mpp.verify(credential_for(cheap), challenge: dear)
    end

    test "a credential echoing our id but a different price" do
      challenge = issue()

      tampered =
        credential_for(challenge, %{
          "request" => Challenge.encode_json(%{"amount" => "1", "credits" => 15_000})
        })

      assert {:error, :challenge_mismatch} = Mpp.verify(tampered, challenge: challenge)
    end

    test "an expired challenge" do
      {:ok, challenge} =
        Mpp.requirements(15_000, expires: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:error, :challenge_expired} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "no issued challenge to compare against" do
      # Trusting the credential's own copy would make the echo check circular.
      challenge = issue()

      assert {:error, :no_issued_challenge} = Mpp.verify(credential_for(challenge), [])
    end

    test "a credential carrying no payment token" do
      challenge = issue()
      credential = %{credential_for(challenge) | payload: %{}}

      assert {:error, :no_payment_token} = Mpp.verify(credential, challenge: challenge)
    end

    test "a payment that has not settled is not money" do
      # Treating "processing" as paid is how a service gives away work for a
      # payment that later fails.
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:ok, intent(%{"status" => "processing"})}
      end)

      assert {:error, {:payment_not_settled, "processing"}} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "an authorisation is not money" do
      # ADR-002: credits are granted against settled money, never an
      # authorisation. requires_capture means the funds are held, not taken,
      # and nothing here captures them (#143).
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:ok, intent(%{"status" => "requires_capture", "amount_received" => 0})}
      end)

      assert {:error, {:payment_not_settled, "requires_capture"}} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "a payment needing customer action is refused distinctly" do
      # An agent cannot complete 3DS. Saying so is more use to it than a
      # generic failure.
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:ok, intent(%{"status" => "requires_action"})}
      end)

      assert {:error, :payment_requires_action} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "a declined payment" do
      challenge = issue()

      expect(Lei.StripeMock, :confirm_shared_payment_token, fn _ ->
        {:error, %{"error" => %{"code" => "card_declined"}}}
      end)

      assert {:error, {:payment_failed, _}} =
               Mpp.verify(credential_for(challenge), challenge: challenge)
    end

    test "something that is not a credential at all" do
      assert {:error, :not_a_credential} = Mpp.verify(%{}, challenge: issue())
    end

    test "no PaymentIntent is created for a mismatched challenge" do
      # The refusal must come before the money moves, not after. Mox fails the
      # test if create_payment_intent is called, since none is expected.
      cheap = issue(100)
      dear = issue(15_000)

      assert {:error, :challenge_mismatch} = Mpp.verify(credential_for(cheap), challenge: dear)
    end
  end
end
