defmodule Lei.StripeWebhookHandlerTest do
  use ExUnit.Case, async: false
  alias Lei.{StripeWebhookHandler, ApiKeys, Repo, Org}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "handle_event/1 — checkout.session.completed" do
    test "activates org on checkout.session.completed" do
      {:ok, org} = ApiKeys.find_or_create_org("Webhook Org", tier: "pro", status: "pending")
      assert org.status == "pending"

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "metadata" => %{"org_id" => to_string(org.id)},
            "customer" => "cus_test_123",
            "subscription" => "sub_test_456"
          }
        }
      }

      assert {:ok, updated_org} = StripeWebhookHandler.handle_event(event)
      assert updated_org.status == "active"
      assert updated_org.stripe_customer_id == "cus_test_123"
      assert updated_org.stripe_subscription_id == "sub_test_456"
    end

    test "extracts subscription_item_id when present" do
      {:ok, org} = ApiKeys.find_or_create_org("Item Org", tier: "pro", status: "pending")

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "metadata" => %{"org_id" => to_string(org.id)},
            "customer" => "cus_item_123",
            "subscription" => "sub_item_456",
            "subscription_items" => %{
              "data" => [%{"id" => "si_metered_789"}]
            }
          }
        }
      }

      assert {:ok, updated_org} = StripeWebhookHandler.handle_event(event)
      assert updated_org.stripe_metered_subscription_item_id == "si_metered_789"
    end

    test "returns error for missing org_id" do
      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "metadata" => %{},
            "customer" => "cus_test_123"
          }
        }
      }

      assert {:error, :missing_org_id} = StripeWebhookHandler.handle_event(event)
    end

    test "returns error for non-existent org" do
      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "metadata" => %{"org_id" => "999999"},
            "customer" => "cus_test_123"
          }
        }
      }

      assert {:error, :org_not_found} = StripeWebhookHandler.handle_event(event)
    end
  end

  describe "handle_event/1 — customer.subscription.deleted" do
    test "suspends org when subscription deleted" do
      {:ok, org} = ApiKeys.find_or_create_org("Sub Del Org", tier: "pro", status: "pending")

      org
      |> Org.stripe_changeset(%{
        status: "active",
        stripe_customer_id: "cus_del_123",
        stripe_subscription_id: "sub_del_456"
      })
      |> Repo.update!()

      event = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "customer" => "cus_del_123",
            "id" => "sub_del_456"
          }
        }
      }

      assert {:ok, updated} = StripeWebhookHandler.handle_event(event)
      assert updated.status == "suspended"
    end

    test "returns error when customer not found" do
      event = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "customer" => "cus_nonexistent",
            "id" => "sub_none"
          }
        }
      }

      assert {:error, :org_not_found} = StripeWebhookHandler.handle_event(event)
    end
  end

  describe "handle_event/1 — invoice.payment_failed" do
    test "suspends org when payment fails" do
      {:ok, org} = ApiKeys.find_or_create_org("Pay Fail Org", tier: "pro", status: "pending")

      org
      |> Org.stripe_changeset(%{
        status: "active",
        stripe_customer_id: "cus_fail_123",
        stripe_subscription_id: "sub_fail_456"
      })
      |> Repo.update!()

      event = %{
        "type" => "invoice.payment_failed",
        "data" => %{
          "object" => %{
            "customer" => "cus_fail_123",
            "id" => "in_fail_789"
          }
        }
      }

      assert {:ok, updated} = StripeWebhookHandler.handle_event(event)
      assert updated.status == "suspended"
    end

    test "returns error when customer not found for payment failure" do
      event = %{
        "type" => "invoice.payment_failed",
        "data" => %{
          "object" => %{
            "customer" => "cus_ghost",
            "id" => "in_ghost"
          }
        }
      }

      assert {:error, :org_not_found} = StripeWebhookHandler.handle_event(event)
    end
  end

  describe "handle_event/1 — unknown events" do
    test "ignores other event types" do
      assert :ok =
               StripeWebhookHandler.handle_event(%{
                 "type" => "payment_intent.succeeded"
               })
    end
  end
end
