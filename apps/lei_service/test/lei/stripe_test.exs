defmodule Lei.StripeTest do
  use ExUnit.Case, async: true

  describe "shared_payment_token_request/1" do
    # The defect in #143 lived here, below the Mox boundary every rail test
    # stops at. These assert the bytes Stripe receives. The shape was checked
    # against sandbox Stripe: payment_method=spt_... is "No such PaymentMethod",
    # payment_method_data[shared_payment_granted_token] succeeds.
    defp spt_request do
      Lei.Stripe.shared_payment_token_request(%{
        amount: 1500,
        currency: "usd",
        spt: "spt_abc",
        idempotency_key: "mpp_ch1_spt_abc",
        metadata: %{"challenge_id" => "ch1"}
      })
    end

    test "passes the token as a shared payment granted token, not a payment method" do
      {body, _headers} = spt_request()
      form = URI.decode_query(body)

      assert form["payment_method_data[shared_payment_granted_token]"] == "spt_abc"
      refute Map.has_key?(form, "payment_method")
    end

    test "confirms immediately, without redirects an agent cannot follow" do
      {body, _headers} = spt_request()
      form = URI.decode_query(body)

      assert form["amount"] == "1500"
      assert form["currency"] == "usd"
      assert form["confirm"] == "true"
      assert form["automatic_payment_methods[enabled]"] == "true"
      assert form["automatic_payment_methods[allow_redirects]"] == "never"
      refute Map.has_key?(form, "return_url")
      assert form["metadata[challenge_id]"] == "ch1"
    end

    test "carries the idempotency key as a header" do
      {_body, headers} = spt_request()
      assert {"Idempotency-Key", "mpp_ch1_spt_abc"} in headers
    end
  end

  describe "payment_intent_request/1" do
    # ACP's charge was the only Stripe write with no Idempotency-Key.
    #
    # Every other money-moving call has one -- the MPP rail (mpp.ex:180), the
    # Tempo verification (tempo.ex:432), refunds (operations.ex:218) -- and
    # this one built its header list as `{body, []}` while
    # create_payment_intent/1 discarded the list entirely with `{body, _}`.
    # So an agent that retried /acp/checkout/:id/complete after a timeout
    # created a second real charge. The session-state guard only helps once
    # the first call has returned; a timeout is precisely the case where it
    # has not.
    defp intent_request do
      Lei.Stripe.payment_intent_request(%{
        amount: 2900,
        currency: "usd",
        payment_method: "pm_card_visa",
        idempotency_key: "acp_sess_123",
        metadata: %{"lei_rail" => "acp", "acp_session_id" => "sess_123"}
      })
    end

    test "carries the idempotency key as a header" do
      {_body, headers} = intent_request()
      assert {"Idempotency-Key", "acp_sess_123"} in headers
    end

    test "still sends the charge itself" do
      {body, _headers} = intent_request()
      form = URI.decode_query(body)

      assert form["amount"] == "2900"
      assert form["currency"] == "usd"
      assert form["payment_method"] == "pm_card_visa"
      assert form["confirm"] == "true"
      assert form["metadata[lei_rail]"] == "acp"
    end

    # A header the caller drops on the floor is the same as no header, and
    # that is the half of this defect the request builder cannot show: the key
    # was built correctly for the SPT path all along while
    # create_payment_intent/1 threw its own away.
    test "the headers actually posted carry the key, not just the ones built" do
      headers =
        Lei.Stripe.payment_intent_headers(%{
          amount: 2900,
          currency: "usd",
          payment_method: "pm_card_visa",
          idempotency_key: "acp_sess_123",
          metadata: %{}
        })

      assert {"Idempotency-Key", "acp_sess_123"} in headers

      # Still a usable request: the key is added to the standard headers,
      # not substituted for them.
      assert Enum.any?(headers, fn {name, _} -> name == "Content-Type" end)
    end
  end

  describe "crypto_verification_request/1" do
    # The shape sandbox Stripe accepted and verified against a real Tempo
    # testnet transfer (#144).
    test "asks Stripe to verify the transfer, in USD, idempotent on the hash" do
      {body, headers} =
        Lei.Stripe.crypto_verification_request(%{
          amount: 50,
          network: "tempo",
          transaction_hash: "0xabc",
          idempotency_key: "tempo_0xabc",
          metadata: %{"challenge_id" => "ch1"}
        })

      form = URI.decode_query(body)

      assert form["amount"] == "50"
      assert form["currency"] == "usd"
      assert form["confirm"] == "true"
      assert form["payment_method_types[]"] == "crypto"
      assert form["payment_method_data[type]"] == "crypto"
      assert form["payment_method_options[crypto][mode]"] == "transaction_verification"

      assert form["payment_method_options[crypto][transaction_verification_options][network]"] ==
               "tempo"

      assert form[
               "payment_method_options[crypto][transaction_verification_options][transaction_hash]"
             ] == "0xabc"

      assert form["metadata[challenge_id]"] == "ch1"
      assert {"Idempotency-Key", "tempo_0xabc"} in headers
    end
  end

  describe "construct_webhook_event/3" do
    test "verifies valid signature" do
      payload = ~s({"type":"checkout.session.completed","data":{"object":{}}})
      secret = "whsec_test_secret"
      timestamp = to_string(System.system_time(:second))
      signed_payload = "#{timestamp}.#{payload}"

      signature =
        :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

      sig_header = "t=#{timestamp},v1=#{signature}"

      assert {:ok, event} = Lei.Stripe.construct_webhook_event(payload, sig_header, secret)
      assert event["type"] == "checkout.session.completed"
    end

    test "rejects invalid signature" do
      payload = ~s({"type":"test"})
      secret = "whsec_test_secret"
      sig_header = "t=1234567890,v1=invalidsignature"

      assert {:error, :invalid_signature} =
               Lei.Stripe.construct_webhook_event(payload, sig_header, secret)
    end

    test "rejects missing timestamp" do
      assert {:error, :invalid_signature} =
               Lei.Stripe.construct_webhook_event("body", "v1=sig", "secret")
    end

    test "rejects missing v1 signature" do
      assert {:error, :invalid_signature} =
               Lei.Stripe.construct_webhook_event("body", "t=123", "secret")
    end
  end
end
