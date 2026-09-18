defmodule Lei.BuyerLocation do
  @moduledoc """
  Where a buyer is, for tax -- and only ever a buyer who has somewhere to be.

  Stripe Tax calculates from an address. On a PaymentIntent it reads shipping,
  then billing, then the payment method's billing details, then IP, and a US
  customer needs at least a 5-digit postal code.

  ## Only a person is asked

  The first version of this checked a location before every purchase, on every
  rail, and answered an agent with a machine-readable "set it here". That was
  wrong at the premise. **An agent has no location to give.** It runs wherever
  it happens to be running and pays from a wallet, so an address it supplied
  would be a number it invented -- and a false address in the ledger is worse
  than an absent one, because it looks like an answer.

  So the location is collected from the one buyer who has one: a person, by
  Stripe Checkout, which asks them directly (`billing_address_collection`).
  This module reads what Stripe collected. There is deliberately no function
  that asks a caller for a location, and none that refuses a caller for not
  having one.

  ## What that leaves for agent purchases

  `mpp`, `tempo` and `acp` record a jurisdiction we genuinely do not know, as
  NULL rather than a guess. Whether tax on those is handled by inclusive
  pricing, by a merchant of record, or by Stripe deriving it from the payment
  instrument itself is a question for the accountant (kitplummer/lei_ops#2).
  It is not one this code can answer by asking, and writing a schema around an
  unresolved tax position would encode whichever answer we guessed.
  """

  @doc """
  The billing location Stripe collected on a Checkout Session, or `nil`.

  Shaped for `Lei.Org.location_changeset/2`. `nil` when Checkout returned no
  address, which is not an error: it means we were not told, and being not told
  is recorded as nothing rather than as a blank location.
  """
  def from_checkout(%{"customer_details" => %{"address" => %{} = address}}) do
    case address["country"] do
      country when is_binary(country) and country != "" ->
        %{billing_country: country, billing_postal_code: address["postal_code"]}

      _ ->
        nil
    end
  end

  def from_checkout(_checkout), do: nil
end
