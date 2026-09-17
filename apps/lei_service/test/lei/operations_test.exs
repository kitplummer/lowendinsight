defmodule Lei.OperationsTest do
  @moduledoc """
  The operations an agent runs from a payment runbook (`scripts/payments.sh`).

  Each takes plain arguments and returns a map that encodes to JSON with an
  `ok` field, because the caller is a script and an agent reading its output,
  not a person reading an IEx session. `Lei.Operations.cli/2` is the single
  entry point the script reaches over `rpc`: its arguments arrive as base64
  JSON, so nothing an agent passes -- a reason with quotes in it, an id that is
  not an id -- is ever evaluated as code.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.{Operations, Payments, Repo, Wallets}
  alias Lei.Payments.Switches

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, org} =
      Wallets.provision("0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)))

    %{org: org}
  end

  defp cli(command, args),
    do: Operations.cli(command, args |> Poison.encode!() |> Base.encode64())

  defp decoded(json), do: Poison.decode!(json)

  describe "status" do
    test "reports every switch, held payments, and the latest reconciliation" do
      %{"ok" => true} = status = cli("status", %{}) |> decoded()

      assert Map.keys(status["switches"]) |> Enum.sort() == ~w(acp mpp pro_checkout tempo)
      assert status["switches"]["tempo"]["enabled"] == true
      assert status["held"] == %{}
      assert Map.has_key?(status, "reconciliation")
    end
  end

  describe "switch" do
    test "switches a path off, with who and why" do
      result =
        cli("switch", %{
          path: "tempo",
          enabled: false,
          reason: "incident: quotes \" and ' survive",
          actor: "agent"
        })
        |> decoded()

      assert %{"ok" => true, "path" => "tempo", "enabled" => false, "changed" => true} = result
      refute Switches.enabled?("tempo")
      assert Switches.state()["tempo"].reason == "incident: quotes \" and ' survive"
    end

    test "switching to the state it is already in changes nothing, so a retry is harmless" do
      cli("switch", %{path: "tempo", enabled: false, reason: "first", actor: "agent"})

      result =
        cli("switch", %{path: "tempo", enabled: false, reason: "retried", actor: "agent"})
        |> decoded()

      assert %{"ok" => true, "changed" => false} = result
      assert length(Switches.history("tempo")) == 1
    end

    test "refuses an unknown path or a missing reason" do
      assert %{"ok" => false, "error" => "unknown_path"} =
               cli("switch", %{path: "paypal", enabled: false, reason: "x", actor: "a"})
               |> decoded()

      assert %{"ok" => false, "error" => "reason_required"} =
               cli("switch", %{path: "tempo", enabled: false, reason: "", actor: "a"})
               |> decoded()
    end
  end

  describe "ledger" do
    test "shows a purchase and what reversed it, and the org's balance", %{org: org} do
      {:ok, _} =
        Payments.credit_settlement(org.id, %{
          credits: 15_000,
          rail: "tempo",
          settlement_ref: "pi_ops_ledger",
          usd_value_cents: 1_500
        })

      :applied =
        Payments.Reversals.refund(%{
          "id" => "ch_ops",
          "payment_intent" => "pi_ops_ledger",
          "amount_refunded" => 500,
          "currency" => "usd"
        })

      result = cli("ledger", %{payment_intent: "pi_ops_ledger"}) |> decoded()

      assert %{"ok" => true, "org_id" => org_id, "balance" => 10_000} = result
      assert org_id == org.id

      assert result["entries"] |> Enum.map(& &1["reason"]) |> Enum.sort() == [
               "purchase:tempo",
               "reversal:tempo"
             ]
    end

    test "an unknown PaymentIntent is not a credit purchase" do
      assert %{"ok" => false, "error" => "not_a_credit_purchase"} =
               cli("ledger", %{payment_intent: "pi_nobody"}) |> decoded()
    end
  end

  describe "refund" do
    setup %{org: org} do
      {:ok, _} =
        Payments.credit_settlement(org.id, %{
          credits: 15_000,
          rail: "mpp",
          settlement_ref: "pi_ops_refund",
          usd_value_cents: 1_500
        })

      :ok
    end

    test "refunds a credit purchase through Stripe, keyed so a retry cannot refund twice" do
      expect(Lei.StripeMock, :create_refund, 2, fn params ->
        assert params.payment_intent == "pi_ops_refund"
        assert params.amount == 500
        assert params.metadata["reason"] == "customer asked"
        assert params.metadata["actor"] == "agent"
        send(self(), {:idempotency_key, params.idempotency_key})
        {:ok, %{"id" => "re_ops", "status" => "succeeded", "amount" => 500}}
      end)

      args = %{
        payment_intent: "pi_ops_refund",
        amount_cents: 500,
        reason: "customer asked",
        actor: "agent"
      }

      assert %{"ok" => true, "refund" => "re_ops", "status" => "succeeded", "amount_cents" => 500} =
               cli("refund", args) |> decoded()

      cli("refund", args)

      assert_received {:idempotency_key, key}
      assert_received {:idempotency_key, ^key}
    end

    test "a full refund leaves the amount to Stripe" do
      expect(Lei.StripeMock, :create_refund, fn params ->
        assert params.amount == nil
        {:ok, %{"id" => "re_full", "status" => "succeeded", "amount" => 1_500}}
      end)

      assert %{"ok" => true, "amount_cents" => 1_500} =
               cli("refund", %{payment_intent: "pi_ops_refund", reason: "full", actor: "agent"})
               |> decoded()
    end

    test "will not refund a payment that is not a credit purchase" do
      # No create_refund expectation: Mox fails the test if Stripe is called.
      assert %{"ok" => false, "error" => "not_a_credit_purchase"} =
               cli("refund", %{payment_intent: "pi_a_subscription", reason: "x", actor: "agent"})
               |> decoded()
    end

    test "will not refund without a reason, or more than was paid" do
      assert %{"ok" => false, "error" => "reason_required"} =
               cli("refund", %{payment_intent: "pi_ops_refund", reason: " ", actor: "agent"})
               |> decoded()

      assert %{"ok" => false, "error" => "amount_exceeds_purchase"} =
               cli("refund", %{
                 payment_intent: "pi_ops_refund",
                 amount_cents: 1_501,
                 reason: "x",
                 actor: "agent"
               })
               |> decoded()
    end

    test "reports Stripe's refusal as a failure" do
      expect(Lei.StripeMock, :create_refund, fn _ ->
        {:error, {400, %{"error" => %{"code" => "charge_already_refunded"}}}}
      end)

      assert %{"ok" => false, "error" => "stripe_refused", "detail" => detail} =
               cli("refund", %{payment_intent: "pi_ops_refund", reason: "x", actor: "agent"})
               |> decoded()

      assert detail =~ "charge_already_refunded"
    end
  end

  describe "held payments and reconciliation" do
    test "list what is held and show the latest reconciliation" do
      assert %{"ok" => true, "held" => []} = cli("held", %{}) |> decoded()
      assert %{"ok" => true, "run" => nil} = cli("reconciliation", %{}) |> decoded()
    end

    test "releasing a payment that is not held says so" do
      assert %{"ok" => false, "error" => "not_held"} =
               cli("release", %{challenge_id: "nope"}) |> decoded()
    end
  end

  describe "the entry point" do
    test "an unknown command, or arguments that are not base64 JSON, fail without evaluating anything" do
      assert %{"ok" => false, "error" => "unknown_command"} =
               Operations.cli("drop_tables", Base.encode64("{}")) |> decoded()

      assert %{"ok" => false, "error" => "invalid_arguments"} =
               Operations.cli("status", "System.halt()") |> decoded()
    end

    test "the Stripe refund request is keyed and carries its metadata" do
      {body, headers} =
        Lei.Stripe.refund_request(%{
          payment_intent: "pi_x",
          amount: 500,
          idempotency_key: "k1",
          metadata: %{"reason" => "r"}
        })

      form = URI.decode_query(body)
      assert form["payment_intent"] == "pi_x"
      assert form["amount"] == "500"
      assert form["metadata[reason]"] == "r"
      assert {"Idempotency-Key", "k1"} in headers

      {full, _} =
        Lei.Stripe.refund_request(%{
          payment_intent: "pi_x",
          amount: nil,
          idempotency_key: "k2",
          metadata: %{}
        })

      refute Map.has_key?(URI.decode_query(full), "amount")
    end
  end
end
