defmodule Lei.StripeWebhookHandlerTest do
  use ExUnit.Case, async: false
  alias Lei.{StripeWebhookHandler, ApiKeys}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "handle_event/1" do
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

    test "ignores other event types" do
      assert :ok =
               StripeWebhookHandler.handle_event(%{
                 "type" => "payment_intent.succeeded"
               })
    end
  end
end
