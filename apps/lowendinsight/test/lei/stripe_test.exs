defmodule Lei.StripeTest do
  use ExUnit.Case, async: true

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
