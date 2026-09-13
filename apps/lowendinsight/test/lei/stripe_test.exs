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
