defmodule Lei.StripePurchaseIdentityTest do
  @moduledoc """
  A credit purchase can be recognised on Stripe's side (#139).

  Reconciling Stripe against the ledger starts from Stripe's PaymentIntents, so
  it has to tell a credit purchase from any other payment. The MPP and
  stablecoin rails already set `metadata.challenge_id`. Agent card checkout
  (ACP) set nothing: its $29 sandbox purchase on 2026-09-16 shows
  `metadata: {}`, indistinguishable from a Pro subscription payment. So a
  purchase Stripe received and the ledger never credited would have been
  invisible on the one path that charges a card directly.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.{Acp, Repo}

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "an ACP purchase tells Stripe it is one, with its session and credits" do
    {:ok, session} = Acp.create_session("lei-credits-29000")
    name = "ACP Identity #{System.unique_integer([:positive])}"
    {:ok, session} = Acp.update_session(session.id, %{customer_name: name})

    expect(Lei.StripeMock, :create_payment_intent, fn params ->
      assert params.metadata == %{
               "lei_rail" => "acp",
               "acp_session_id" => session.id,
               "credits" => "29000"
             }

      {:ok, %{"id" => "pi_acp_identity", "status" => "succeeded"}}
    end)

    assert {:ok, _} = Acp.complete_session(session.id, %{"payment_method" => "pm_card_visa"})
  end

  test "the metadata reaches Stripe in the request body" do
    {body, _headers} =
      Lei.Stripe.payment_intent_request(%{
        amount: 2900,
        currency: "usd",
        payment_method: "pm_card_visa",
        idempotency_key: "acp_sess_identity",
        metadata: %{"lei_rail" => "acp", "credits" => "29000"}
      })

    form = URI.decode_query(body)
    assert form["metadata[lei_rail]"] == "acp"
    assert form["metadata[credits]"] == "29000"
    assert form["amount"] == "2900"
    assert form["confirm"] == "true"
  end

  test "listing asks for the window's PaymentIntents with their charges, and pages" do
    first = Lei.Stripe.list_payment_intents_path(1_789_000_000, nil)
    next = Lei.Stripe.list_payment_intents_path(1_789_000_000, "pi_last")

    for path <- [first, next] do
      query = path |> URI.parse() |> Map.fetch!(:query) |> URI.query_decoder() |> Enum.to_list()
      assert URI.parse(path).path == "/v1/payment_intents"
      assert {"created[gte]", "1789000000"} in query
      assert {"expand[]", "data.latest_charge"} in query
      assert {"limit", "100"} in query
    end

    refute first =~ "starting_after"
    assert next =~ "starting_after=pi_last"
  end

  # The session is the charge's identity. Asserted through Acp.complete_session
  # rather than on the request builder, because the defect was that nothing
  # passed a key at all -- the builder was reachable only with one supplied by
  # hand, which is how it looked correct.
  test "the charge is keyed to the session, so a retried completion cannot charge twice" do
    {:ok, session} = Acp.create_session("lei-credits-29000")
    name = "ACP Idem #{System.unique_integer([:positive])}"
    {:ok, session} = Acp.update_session(session.id, %{customer_name: name})

    expect(Lei.StripeMock, :create_payment_intent, fn params ->
      assert params.idempotency_key == "acp_" <> to_string(session.id)
      {:ok, %{"id" => "pi_acp_idem", "status" => "succeeded"}}
    end)

    assert {:ok, _} = Acp.complete_session(session.id, %{"payment_method" => "pm_card_visa"})
  end
end
