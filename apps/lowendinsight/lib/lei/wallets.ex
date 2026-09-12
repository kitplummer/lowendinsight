defmodule Lei.Wallets do
  @moduledoc """
  Orgs identified by a wallet rather than by a person. See ADR-002.

  ## Why there is no public provisioning endpoint here

  The obvious design -- an unauthenticated endpoint that takes a wallet address
  and returns an API key -- is org takeover. A wallet address is public. Anyone
  can present someone else's, and find-or-create semantics would hand them a
  credential for an org holding that wallet's credits. That is #89's bug in a
  new costume, and the reason `Lei.ApiKeys.find_or_create_org/2` carries the
  warning it does.

  Issue #103 suggested first payment could serve as proof of control. That is
  right, but only if provisioning happens *at* payment verification rather than
  before it: an attacker targets a wallet that has **already** funded, so
  "an unfunded org can do nothing" does not protect the case that matters.

  So provisioning is an internal API with create-only semantics. The caller is
  responsible for having verified control first, and the only such caller will
  be x402 payment verification (#104), where the on-chain payment *is* the
  proof. Composing the two is deliberately left to that stage rather than
  guessed at here.

  `provision/2` never returns an existing org. A caller that wants
  find-or-create must ask for it explicitly, in a context where it has already
  established that the requester controls the address.
  """

  import Ecto.Query

  alias Lei.{Org, Repo}

  @doc """
  Looks up the org holding this wallet, if any.
  """
  def find_by_address(address) do
    case Org.normalise_wallet(address) do
      nil ->
        nil

      normalised ->
        Repo.one(from(o in Org, where: o.wallet_address == ^normalised))
    end
  end

  @doc """
  Creates an org for a wallet that does not have one.

  Returns `{:error, :wallet_taken}` if the address already holds an org --
  never that org. Deciding whether the requester is entitled to it is the
  caller's job, and it needs proof this function does not have.

  Options: `:name` for a human-readable label; everything else follows from
  ADR-002 and is not configurable, because the safety of this path depends on
  it.
  """
  def provision(address, opts \\ []) do
    normalised = Org.normalise_wallet(address)
    name = Keyword.get(opts, :name) || default_name(normalised)

    %Org{}
    |> Org.wallet_changeset(%{
      name: name,
      wallet_address: normalised,
      tier: "free",
      status: "active"
    })
    # No free tier for agents. A wallet costs nothing to create, so a free
    # allowance per wallet is a free allowance per attacker -- ADR-002 closes
    # the farming vector by not granting one, rather than rate-limiting around
    # it. Access comes from credits, and a new org has none.
    |> Ecto.Changeset.put_change(:free_tier_analyses_limit, 0)
    |> Repo.insert()
    |> case do
      {:ok, org} ->
        {:ok, org}

      # The unique index refused it. Deliberately not a pre-check SELECT:
      # two concurrent provisioning requests both pass a pre-check, and only
      # one can win an index.
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # Either index means the same thing here: a wallet org's slug is a pure
        # function of its address, in a namespace ordinary signup cannot reach,
        # so a slug collision can only be this wallet colliding with itself.
        # Which index fires first is a detail of constraint ordering, not
        # something callers should have to know.
        if unique_violation?(errors) do
          {:error, :wallet_taken}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Whether this org is identified by a wallet.
  """
  def wallet_org?(%Org{wallet_address: address}), do: is_binary(address) and address != ""
  def wallet_org?(_), do: false

  # Only a constraint violation means the wallet is taken. A malformed address
  # also puts an error on :wallet_address, and reporting that as "taken" would
  # tell a caller their address belongs to someone else when it is simply not
  # an address.
  defp unique_violation?(errors) do
    Enum.any?(errors, fn
      {field, {_message, opts}} when field in [:wallet_address, :slug] ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp default_name(address) when is_binary(address) do
    # Slugs are generated from the name, so it has to be unique per wallet.
    # The address already is.
    "wallet-" <> address
  end

  defp default_name(_), do: "wallet-unknown"
end
