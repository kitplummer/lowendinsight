defmodule Lei.CheckoutLocationTest do
  @moduledoc """
  Stripe Checkout asks the person for a billing address, and we keep it.

  This is the whole of the buyer-location story after #223 was reframed: a
  person has a location and Stripe can ask them for it, so that is where it
  comes from. An agent has none to give and is never asked -- see
  `Lei.BuyerLocationTest`.

  The address arrives on the Checkout Session, by both routes that activate a
  Pro org: the customer returning to `/signup/success`, and the
  `checkout.session.completed` webhook. Either may be first, so both store it.

  **An address must never cost someone their activation.** They have paid by
  the time we see it. A location Stripe returns that we cannot use is dropped
  with a log line rather than failing the write that makes their account work.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.{ApiKeys, Org, Repo, Signup}

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp pending_pro do
    {:ok, org} =
      ApiKeys.create_org("Checkout Loc #{System.unique_integer([:positive])}",
        tier: "pro",
        status: "pending"
      )

    org
  end

  defp checkout(org, address) do
    %{
      "id" => "cs_test_loc",
      "object" => "checkout.session",
      "status" => "complete",
      "payment_status" => "paid",
      "customer" => "cus_loc",
      "subscription" => "sub_loc",
      "customer_details" => %{"address" => address},
      "metadata" => %{"org_id" => to_string(org.id)}
    }
  end

  describe "Checkout is told to collect an address" do
    test "the request asks for one, because Stripe Tax has nothing to work from otherwise" do
      {body, _headers} =
        Lei.Stripe.checkout_session_request(%{
          price_id: "price_pro",
          success_url: "https://lowendinsight.dev/ok",
          cancel_url: "https://lowendinsight.dev/no",
          org_id: 1
        })

      assert URI.decode_query(body)["billing_address_collection"] == "required"
    end

    test "the rest of the subscription request is unchanged" do
      {body, _headers} =
        Lei.Stripe.checkout_session_request(%{
          price_id: "price_pro",
          metered_price_id: "price_metered",
          success_url: "https://lowendinsight.dev/ok",
          cancel_url: "https://lowendinsight.dev/no",
          org_id: 7
        })

      form = URI.decode_query(body)

      assert form["mode"] == "subscription"
      assert form["line_items[0][price]"] == "price_pro"
      assert form["line_items[1][price]"] == "price_metered"
      assert form["metadata[org_id]"] == "7"
    end
  end

  describe "the returning customer's address is kept" do
    test "a completed checkout stores what Stripe collected" do
      org = pending_pro()

      expect(Lei.StripeMock, :retrieve_checkout_session, fn "cs_test_loc" ->
        {:ok, checkout(org, %{"country" => "GB", "postal_code" => "SW1A 1AA"})}
      end)

      assert {:ok, _org} = Signup.confirm_paid_checkout(org, "cs_test_loc")

      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.billing_country == "GB"
      assert org.billing_postal_code == "SW1A 1AA"
    end

    test "a checkout with no address activates anyway, holding no location" do
      org = pending_pro()

      expect(Lei.StripeMock, :retrieve_checkout_session, fn _ ->
        {:ok, checkout(org, nil)}
      end)

      assert {:ok, _org} = Signup.confirm_paid_checkout(org, "cs_test_loc")

      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.billing_country == nil
    end

    # They have already paid. Refusing the write that makes their account work,
    # over an address, would be the wrong thing to protect.
    test "an address Stripe returns that we cannot use does not cost them activation" do
      org = pending_pro()

      expect(Lei.StripeMock, :retrieve_checkout_session, fn _ ->
        {:ok, checkout(org, %{"country" => "US", "postal_code" => nil})}
      end)

      assert {:ok, _org} = Signup.confirm_paid_checkout(org, "cs_test_loc")

      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.stripe_customer_id == "cus_loc"
      # Dropped rather than stored half-formed: Stripe cannot calculate US tax
      # without a ZIP, so a US country on its own is not a location.
      assert org.billing_country == nil
    end
  end

  describe "the webhook keeps it too" do
    test "checkout.session.completed stores the address" do
      org = pending_pro()

      assert {:ok, _} =
               Lei.StripeWebhookHandler.handle_event(%{
                 "type" => "checkout.session.completed",
                 "data" => %{
                   "object" => checkout(org, %{"country" => "IE", "postal_code" => "D02"})
                 }
               })

      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.billing_country == "IE"
    end

    test "an unusable address does not stop the org being activated" do
      org = pending_pro()

      assert {:ok, _} =
               Lei.StripeWebhookHandler.handle_event(%{
                 "type" => "checkout.session.completed",
                 "data" => %{"object" => checkout(org, %{"country" => "US", "postal_code" => ""})}
               })

      org = Repo.get!(Org, org.id)
      assert org.status == "active"
      assert org.billing_country == nil
    end
  end
end
