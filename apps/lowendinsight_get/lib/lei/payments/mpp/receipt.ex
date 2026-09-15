defmodule Lei.Payments.Mpp.Receipt do
  @moduledoc """
  The `Payment-Receipt` header returned alongside a paid response.

  `reference` is the payment network's own identifier for the settlement, and
  it becomes the settlement's `settlement_ref` -- which in turn becomes
  `credit_entries.external_ref`, namespaced by rail. That chain is what makes a
  replayed payment harmless, so the reference has to be the network's and not
  one we invent: two of ours could differ for one settlement.
  """

  @enforce_keys [:method, :reference]
  defstruct [:method, :reference, :status, :timestamp]

  @type t :: %__MODULE__{
          method: String.t(),
          reference: String.t(),
          status: String.t(),
          timestamp: DateTime.t() | nil
        }

  def new(opts) do
    %__MODULE__{
      method: Keyword.fetch!(opts, :method),
      reference: Keyword.fetch!(opts, :reference),
      status: Keyword.get(opts, :status, "success"),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end

  def to_header(%__MODULE__{} = r) do
    %{
      "status" => r.status,
      "method" => r.method,
      "reference" => r.reference,
      "timestamp" => r.timestamp && DateTime.to_iso8601(r.timestamp)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.into(%{})
    |> Poison.encode!()
    |> Base.url_encode64(padding: false)
  end

  def from_header(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"method" => method, "reference" => reference} = map} <- Poison.decode(json) do
      {:ok,
       %__MODULE__{
         method: method,
         reference: reference,
         status: Map.get(map, "status", "success"),
         timestamp: parse_timestamp(map["timestamp"])
       }}
    else
      _ -> {:error, :malformed_receipt}
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
