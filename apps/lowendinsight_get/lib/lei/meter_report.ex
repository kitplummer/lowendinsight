defmodule Lei.MeterReport do
  @moduledoc """
  A record of telling Stripe about metered usage, and whether it worked.

  The meter call happens outside the transaction that writes the usage row and
  its debit -- an HTTP call inside one holds a database connection for its
  whole duration. So the local record and what Stripe has been told can
  diverge, and until now nothing wrote down that it had.

  The failure is under-billing: usage consumed, ledger debited, Stripe never
  informed. It errs against us rather than the customer, which is the right
  direction and still worth knowing about.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(ok failed)

  schema "meter_reports" do
    field(:analysis_usage_id, :integer)
    field(:identifier, :string)
    field(:units, :integer)
    field(:status, :string)
    field(:error, :string)
    belongs_to(:org, Lei.Org)

    timestamps(updated_at: false)
  end

  def statuses, do: @statuses

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:org_id, :analysis_usage_id, :identifier, :units, :status, :error])
    |> validate_required([:org_id, :identifier, :units, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:org_id)
    |> unique_constraint(:identifier)
  end
end
