defmodule Lei.BuyerLocationTest do
  @moduledoc """
  Where a buyer is, for tax -- and only ever a buyer we can ask.

  The first design of this checked a location before every purchase, on every
  rail, and answered an agent with a machine-readable "set it here". That was
  wrong at the premise: **an agent has no location to give.** It runs wherever
  it happens to be running and pays from a wallet, and an address it typed
  would be a number it invented. Asking for one produces a field that is either
  empty or false, and a false address in the ledger is worse than an absent
  one.

  So a location is collected from the one buyer who has one: a person, by
  Stripe Checkout, which asks them directly. We never ask an agent, and we
  never offer an agent a way to tell us.

  What that leaves for agent purchases -- mpp, tempo, acp -- is a jurisdiction
  we genuinely do not know, recorded as NULL rather than guessed. Whether tax
  on those is handled by inclusive pricing, by a merchant of record, or by
  Stripe deriving it from the payment itself is a question for the accountant
  (kitplummer/lei_ops#2), not one this code can answer by asking.
  """
  use ExUnit.Case, async: true

  alias Lei.BuyerLocation
  alias Lei.Org

  describe "location_changeset/2" do
    test "a country alone is enough outside the US" do
      cs = Org.location_changeset(%Org{}, %{billing_country: "DE"})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :billing_country) == "DE"
    end

    test "the country is upcased and the postal code trimmed" do
      cs =
        Org.location_changeset(%Org{}, %{billing_country: " us ", billing_postal_code: " 94110 "})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :billing_country) == "US"
      assert Ecto.Changeset.get_field(cs, :billing_postal_code) == "94110"
    end

    test "a US location without a postal code is rejected" do
      cs = Org.location_changeset(%Org{}, %{billing_country: "US"})

      refute cs.valid?
      assert {"is required for a US location", _} = cs.errors[:billing_postal_code]
    end

    test "a US postal code that Stripe cannot use is rejected" do
      for code <- ["9411", "ABCDE", "94110-", "941101234"] do
        cs = Org.location_changeset(%Org{}, %{billing_country: "US", billing_postal_code: code})

        refute cs.valid?, "expected #{code} to be rejected"
      end

      assert Org.location_changeset(%Org{}, %{
               billing_country: "US",
               billing_postal_code: "94110-1234"
             }).valid?
    end

    test "a country that is not two letters is rejected" do
      for country <- ["USA", "U", "12", ""] do
        refute Org.location_changeset(%Org{}, %{billing_country: country}).valid?,
               "expected #{inspect(country)} to be rejected"
      end
    end

    test "no country at all is rejected" do
      refute Org.location_changeset(%Org{}, %{}).valid?
    end
  end

  describe "from_checkout/1" do
    defp checkout(address) do
      %{
        "id" => "cs_test_1",
        "customer" => "cus_1",
        "customer_details" => %{"address" => address}
      }
    end

    test "takes the country and postal code Stripe collected" do
      assert BuyerLocation.from_checkout(
               checkout(%{"country" => "GB", "postal_code" => "SW1A 1AA"})
             ) == %{billing_country: "GB", billing_postal_code: "SW1A 1AA"}
    end

    test "a US address keeps its ZIP, which Stripe requires to calculate" do
      assert %{billing_country: "US", billing_postal_code: "97209"} =
               BuyerLocation.from_checkout(
                 checkout(%{"country" => "US", "postal_code" => "97209"})
               )
    end

    test "a checkout with no address at all yields nothing, rather than a blank location" do
      assert BuyerLocation.from_checkout(checkout(nil)) == nil
      assert BuyerLocation.from_checkout(%{"id" => "cs_test_1"}) == nil
      assert BuyerLocation.from_checkout(checkout(%{"country" => nil})) == nil
    end
  end

  describe "the surface an agent could use" do
    # These are the functions the first design exposed. Their absence is the
    # feature: a location is something we are told by a person through Stripe,
    # never something a caller supplies, so there is nothing for an agent to
    # set and nothing that refuses it for not having.
    test "there is no way to ask a caller for a location, and no refusal to send one" do
      # function_exported?/3 answers false for a module that is merely not
      # loaded, which would make this pass while every function it names still
      # existed. Load it first, then read the exports off the module itself.
      {:module, _} = Code.ensure_loaded(BuyerLocation)
      exported = BuyerLocation.__info__(:functions)

      for {name, arity} <- [check: 1, refusal: 0, refusal: 1, required?: 0] do
        refute {name, arity} in exported,
               "Lei.BuyerLocation.#{name}/#{arity} is back: an agent has no location to give"
      end
    end
  end
end
