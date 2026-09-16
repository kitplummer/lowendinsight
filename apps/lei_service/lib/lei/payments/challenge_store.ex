defmodule Lei.Payments.ChallengeStore do
  @moduledoc """
  Records the challenges we have issued, so a credential's echo can be checked
  against something real.

  A credential proves that a payment happened. It does not prove who it was
  for. Storing the org alongside the challenge is what stops one agent's
  credential topping up another's balance -- or being spent against a challenge
  issued to someone else entirely.
  """

  import Ecto.Query

  alias Lei.{Repo, Payments.Mpp.Challenge}

  defmodule Record do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    schema "payment_challenges" do
      field(:challenge_id, :string)
      field(:rail, :string)
      field(:credits, :integer)
      field(:amount_cents, :integer)
      field(:header, :string)
      field(:expires_at, :utc_datetime_usec)
      field(:settled_at, :utc_datetime_usec)
      belongs_to(:org, Lei.Org)

      timestamps(updated_at: false)
    end

    def changeset(record, attrs) do
      record
      |> cast(attrs, [
        :challenge_id,
        :org_id,
        :rail,
        :credits,
        :amount_cents,
        :header,
        :expires_at,
        :settled_at
      ])
      # org_id is absent for a challenge issued to an agent that has no org
      # yet; settlement records the org the payment identified (#147).
      |> validate_required([
        :challenge_id,
        :rail,
        :credits,
        :amount_cents,
        :header,
        :expires_at
      ])
      |> unique_constraint(:challenge_id)
      |> foreign_key_constraint(:org_id)
    end
  end

  @doc """
  Records an issued challenge.
  """
  def put(%Challenge{} = challenge, org_id, rail) do
    %Record{}
    |> Record.changeset(%{
      challenge_id: challenge.id,
      org_id: org_id,
      rail: rail.name(),
      credits: challenge.request["credits"],
      amount_cents: String.to_integer(challenge.request["amount"]),
      header: Challenge.to_header(challenge),
      expires_at: challenge.expires || DateTime.add(DateTime.utc_now(), 300, :second)
    })
    |> Repo.insert()
  end

  @doc """
  Looks up an issued challenge by id.

  Returns the parsed challenge, the org it was issued to and the rail that
  issued it. A challenge we cannot find is refused rather than trusted: the
  alternative is accepting a credential's own account of what it is answering.

  A settled challenge is **still returned**. An agent whose response was lost
  retries with the same credential, and that retry must succeed: the ledger's
  unique `external_ref` makes the second credit impossible, so the retry is
  answered with a receipt rather than an error (Lei.Payments.Http, and the
  tests that pin it). Refusing it here would turn a dropped response into a
  failed payment the agent cannot recover from.
  """
  def fetch(challenge_id) when is_binary(challenge_id) do
    case Repo.one(from(r in Record, where: r.challenge_id == ^challenge_id)) do
      nil ->
        {:error, :unknown_challenge}

      record ->
        case Challenge.from_header(record.header) do
          {:ok, challenge} -> {:ok, challenge, record}
          error -> error
        end
    end
  end

  def fetch(_), do: {:error, :no_challenge_id}

  @doc """
  Marks a challenge settled.

  Only bookkeeping -- the ledger is what says a payment happened, and the
  unique index on `credit_entries.external_ref` is what stops it happening
  twice. This makes "issued and never answered" countable, which is the number
  that says whether the on-ramp is working.
  """
  def mark_settled(%Record{} = record, org_id \\ nil) do
    record
    |> Record.changeset(%{settled_at: DateTime.utc_now(), org_id: record.org_id || org_id})
    |> Repo.update()
  end

  @doc """
  Removes challenges that expired without being answered.

  They are not interesting after the fact and there is no reason to keep an
  agent's browsing history of prices.
  """
  def purge_expired(before \\ DateTime.utc_now()) do
    {count, _} =
      Repo.delete_all(from(r in Record, where: is_nil(r.settled_at) and r.expires_at < ^before))

    count
  end
end
