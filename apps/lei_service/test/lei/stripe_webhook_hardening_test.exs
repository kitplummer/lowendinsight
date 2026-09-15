defmodule Lei.StripeWebhookHardeningTest do
  @moduledoc """
  A Stripe webhook is acted on once, only when recent, and only for what was
  actually paid.

  Found in the 2026-09-14 security review:
  - the signature's `t=` timestamp was never compared with the clock, so a
    captured signed delivery could be replayed forever;
  - event ids were not recorded, so a replay was processed again;
  - `checkout.session.completed` activated the org without checking
    `payment_status`, and activated whatever status the org had -- replaying an
    old completion re-activated an org suspended for cancellation or failed
    payment;
  - only the first `v1` signature was compared, which fails during a secret
    rotation, when Stripe signs with both;
  - the route answered 200 whatever the handler did, so a delivery that failed
    to apply was never retried.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Mox

  alias Lei.{ApiKeys, Org, Repo}

  @secret "whsec_test_secret_for_hardening"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    stub(Lei.StripeMock, :construct_webhook_event, fn payload, signature, secret ->
      Lei.Stripe.construct_webhook_event(payload, signature, secret)
    end)

    original = Application.get_env(:lei_service, :stripe_webhook_secret)
    Application.put_env(:lei_service, :stripe_webhook_secret, @secret)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lei_service, :stripe_webhook_secret, original),
        else: Application.delete_env(:lei_service, :stripe_webhook_secret)
    end)

    :ok
  end

  defp signature(body, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, System.system_time(:second))
    secret = Keyword.get(opts, :secret, @secret)
    sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{sig}"
  end

  defp deliver(body, sig) do
    conn(:post, "/webhooks/stripe", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", sig)
    |> put_private(:raw_body, body)
    |> Lei.Web.Router.call(Lei.Web.Router.init([]))
  end

  defp org(status) do
    {:ok, org} =
      ApiKeys.create_org("Webhook Hardening #{System.unique_integer([:positive])}",
        tier: "pro",
        status: status
      )

    org
  end

  defp completed(org, overrides \\ %{}) do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.completed",
      "data" => %{
        "object" =>
          Map.merge(
            %{
              "object" => "checkout.session",
              "status" => "complete",
              "payment_status" => "paid",
              "customer" => "cus_hardening",
              "subscription" => "sub_hardening",
              "metadata" => %{"org_id" => to_string(org.id)}
            },
            overrides
          )
      }
    }
  end

  defp status(org), do: Repo.get!(Org, org.id).status

  describe "signature" do
    test "a correctly signed delivery older than the tolerance is refused" do
      body = Poison.encode!(completed(org("pending")))
      old = System.system_time(:second) - 301

      assert {:error, :timestamp_outside_tolerance} =
               Lei.Stripe.construct_webhook_event(body, signature(body, timestamp: old), @secret)
    end

    test "a timestamp from the future beyond the tolerance is refused" do
      body = ~s({"id":"evt_future","type":"ping"})
      future = System.system_time(:second) + 301

      assert {:error, :timestamp_outside_tolerance} =
               Lei.Stripe.construct_webhook_event(
                 body,
                 signature(body, timestamp: future),
                 @secret
               )
    end

    test "during a rotation, any matching v1 signature is accepted" do
      body = ~s({"id":"evt_rotation","type":"ping"})
      ts = System.system_time(:second)
      "t=" <> _ = good = signature(body, timestamp: ts)
      [_, good_v1] = String.split(good, ",v1=")
      header = "t=#{ts},v1=#{String.duplicate("0", 64)},v1=#{good_v1}"

      assert {:ok, %{"id" => "evt_rotation"}} =
               Lei.Stripe.construct_webhook_event(body, header, @secret)
    end

    test "a signed body that is not JSON is an error, not a crash" do
      body = "not json"

      assert {:error, :invalid_payload} =
               Lei.Stripe.construct_webhook_event(body, signature(body), @secret)
    end

    test "the route refuses a replayed old delivery without acting on it" do
      Lei.WebhookStats.reset()
      pending = org("pending")
      body = Poison.encode!(completed(pending))

      conn = deliver(body, signature(body, timestamp: System.system_time(:second) - 3600))

      assert conn.status == 400
      assert status(pending) == "pending"

      # Counted as stale, not invalid: the monitor alerts on invalid as a
      # signing-secret mismatch, which a replay is not.
      assert Lei.WebhookStats.count(:stale) == 1
      assert Lei.WebhookStats.count(:invalid) == 0
    end
  end

  describe "each event is acted on once" do
    test "a redelivered event does nothing the second time" do
      org = org("pending")
      body = Poison.encode!(completed(org))

      assert deliver(body, signature(body)).status == 200
      assert status(org) == "active"

      # Cancelled since. A redelivery of the old completion must not undo that.
      Repo.get!(Org, org.id) |> Org.stripe_changeset(%{status: "suspended"}) |> Repo.update!()

      second = deliver(body, signature(body))
      assert second.status == 200
      assert Poison.decode!(second.resp_body)["status"] == "duplicate"
      assert status(org) == "suspended"
    end

    test "a delivery whose handling fails is not recorded, so Stripe's retry is processed" do
      org = org("pending")
      # An org id that cannot be cast makes the handler raise.
      bad = completed(org, %{"metadata" => %{"org_id" => "not-a-number"}})
      body = Poison.encode!(bad)

      assert deliver(body, signature(body)).status == 500
      refute Repo.get(Lei.StripeEvent, bad["id"])
    end

    test "an event with no id is refused" do
      body = ~s({"type":"checkout.session.completed","data":{"object":{}}})
      assert deliver(body, signature(body)).status == 400
    end
  end

  describe "checkout.session.completed" do
    test "an unpaid completion activates nothing" do
      org = org("pending")
      body = Poison.encode!(completed(org, %{"payment_status" => "unpaid"}))

      assert deliver(body, signature(body)).status == 200
      assert status(org) == "pending"
    end

    test "a suspended org is not re-activated" do
      org = org("suspended")
      body = Poison.encode!(completed(org))

      assert deliver(body, signature(body)).status == 200
      assert status(org) == "suspended"
    end

    test "a paid completion activates a pending org and records billing ids" do
      org = org("pending")
      body = Poison.encode!(completed(org))

      assert deliver(body, signature(body)).status == 200
      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.stripe_customer_id == "cus_hardening"
      assert org.stripe_subscription_id == "sub_hardening"
    end

    test "an async payment that later succeeds activates the org" do
      org = org("pending")
      event = completed(org) |> Map.put("type", "checkout.session.async_payment_succeeded")
      body = Poison.encode!(event)

      assert deliver(body, signature(body)).status == 200
      assert status(org) == "active"
    end
  end
end
