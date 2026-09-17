defmodule Lei.Payments.Held do
  @moduledoc """
  Payments received while their rail was switched off, and not yet credited.

  A stablecoin agent sends its transfer on chain before it presents the
  credential, so refusing the credential does not return the money
  (`Lei.Payments.MachineRail.funds_move_before_settlement?/1`). The refused
  challenge and credential are kept -- the challenge is not purged -- and an
  operator decides what happens to each once the incident is over:

    * **credit it**: `release/1` verifies the transfer and credits the payer
      exactly as a normal settlement would, including creating the Stripe
      record of the payment. It works with the rail still off and after the
      challenge has expired, because it is an operator's decision, not an
      agent's retry.
    * **refund it**: release it first, then refund the resulting PaymentIntent
      in Stripe. Stripe records stablecoin only once we ask it to verify the
      transaction, so there is nothing in Stripe to refund until then; the
      refund then comes back through `Lei.Payments.Reversals` like any other.

  See `apps/lei_service/docs/OPERATIONS.md`, "Payment kill switch".
  """

  import Ecto.Query

  alias Lei.Repo
  alias Lei.Payments.{ChallengeStore, Http}

  @doc "Held payments not yet credited, oldest first."
  def list do
    Repo.all(
      from(r in ChallengeStore.Record,
        where: not is_nil(r.held_at) and is_nil(r.settled_at),
        order_by: [asc: r.held_at],
        select: %{
          challenge_id: r.challenge_id,
          rail: r.rail,
          credits: r.credits,
          amount_cents: r.amount_cents,
          org_id: r.org_id,
          held_at: r.held_at
        }
      )
    )
  end

  @doc "Held payments not yet credited, counted by rail."
  def counts do
    Repo.all(
      from(r in ChallengeStore.Record,
        where: not is_nil(r.held_at) and is_nil(r.settled_at),
        group_by: r.rail,
        select: {r.rail, count(r.id)}
      )
    )
    |> Map.new()
  end

  @doc """
  Verifies and credits a held payment. `{:ok, settlement}`, `{:error, :not_held}`
  for a challenge that is not held or already credited, or the rail's refusal.
  """
  def release(challenge_id) when is_binary(challenge_id) do
    case Repo.one(
           from(r in ChallengeStore.Record,
             where:
               r.challenge_id == ^challenge_id and not is_nil(r.held_at) and is_nil(r.settled_at)
           )
         ) do
      nil ->
        {:error, :not_held}

      record ->
        # Settlement reads the credential from a request, so it is given one
        # carrying the held credential and nothing else.
        %Plug.Conn{}
        |> Plug.Conn.put_req_header("authorization", record.held_credential)
        |> Http.settle(release_held: true)
        |> case do
          {:ok, _conn, settlement} -> {:ok, settlement}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  def release(_), do: {:error, :not_held}
end
