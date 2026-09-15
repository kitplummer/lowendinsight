defmodule Lei.Tempo.RpcBehaviour do
  @callback get_transaction_receipt(rpc_url :: String.t(), hash :: String.t()) ::
              {:ok, map()} | {:error, :not_found} | {:error, term()}
end

defmodule Lei.Tempo.Rpc do
  @moduledoc """
  The one chain read this service makes: a transaction receipt.

  Not a chain client. It exists because Stripe verifies that a transfer paid our
  deposit address the right amount, but not *which challenge* it paid -- the
  memo that binds it is not in anything Stripe returns. Transaction hashes are
  public, so without this anyone watching the chain could present another
  agent's payment as their own (#144).
  """

  @behaviour Lei.Tempo.RpcBehaviour

  def impl, do: Application.get_env(:lowendinsight, :tempo_rpc_module, __MODULE__)

  @impl true
  def get_transaction_receipt(rpc_url, hash) do
    body =
      Poison.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getTransactionReceipt",
        params: [hash]
      })

    case HTTPoison.post(rpc_url, body, [{"Content-Type", "application/json"}],
           recv_timeout: 10_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp}} ->
        case Poison.decode(resp) do
          # Unknown or not yet mined. Not an error in the node's terms, and not
          # a payment in ours.
          {:ok, %{"result" => nil}} -> {:error, :not_found}
          {:ok, %{"result" => %{} = receipt}} -> {:ok, receipt}
          {:ok, %{"error" => error}} -> {:error, {:rpc_error, error}}
          _ -> {:error, :unparseable_response}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
