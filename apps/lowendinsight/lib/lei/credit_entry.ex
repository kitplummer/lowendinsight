defmodule Lei.CreditEntry do
  @moduledoc """
  One movement of credits, in or out. Append-only.

  Balance is the sum of deltas over an org -- there is deliberately no balance
  column. A balance can tell you what is owed; it cannot tell you how it got
  there, or what was earned and when. See ADR-002.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(
    grant:subscription
    purchase:stripe
    purchase:x402
    debit:analysis
    adjustment:manual
    expiry
  )

  schema "credit_entries" do
    field(:delta, :integer)
    field(:reason, :string)
    field(:external_ref, :string)
    field(:usd_value_cents, :integer)
    field(:jurisdiction, :string)
    field(:metadata, :map, default: %{})
    belongs_to(:org, Lei.Org)

    timestamps(updated_at: false)
  end

  def reasons, do: @reasons

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :org_id,
      :delta,
      :reason,
      :external_ref,
      :usd_value_cents,
      :jurisdiction,
      :metadata
    ])
    |> validate_required([:org_id, :delta, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_exclusion(:delta, [0], message: "must be non-zero")
    |> foreign_key_constraint(:org_id)
    |> unique_constraint(:external_ref)
  end
end
