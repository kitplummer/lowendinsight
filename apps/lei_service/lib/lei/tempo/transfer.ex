defmodule Lei.Tempo.Transfer do
  @moduledoc """
  Finds the payment for a challenge in a transaction receipt.

  A match requires every one of: the transaction succeeded; a `TransferWithMemo`
  log was emitted by the expected token contract; it paid our deposit address;
  its memo is the one issued with this challenge; and it moved at least the
  amount asked. A log's `address` is the contract that emitted it and cannot be
  set by anyone else, so a look-alike token cannot pass.

  Log layout observed on Tempo testnet (#144):

      topics[0]  0x57bc7354...  TransferWithMemo(address,address,uint256,bytes32)
      topics[1]  from, left-padded to 32 bytes
      topics[2]  to, left-padded to 32 bytes
      topics[3]  memo
      data       amount, uint256

  A transfer also emits a plain `Transfer` log, and the fee payment is a second
  `Transfer` to the fee manager. Neither carries a memo, so neither can match.
  """

  @transfer_with_memo "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"

  def transfer_with_memo_topic, do: @transfer_with_memo

  @doc """
  `expected` is `%{token:, recipient:, memo:, amount:}`, amount in token units.

  Returns `{:ok, %{amount:, from:}}` or `{:error, reason}`.
  """
  def find_payment(%{} = receipt, expected) do
    if receipt["status"] != "0x1" do
      {:error, :transaction_failed}
    else
      matches =
        receipt
        |> Map.get("logs", [])
        |> Enum.flat_map(&decode(&1, expected))

      # The payer is who an org and a key are issued to (#147), so the token
      # holder must be the account that signed. A TIP-20 transferFrom lets an
      # approved spender move a holder's tokens: without this, anyone holding
      # an allowance from a wallet could pay "as" that wallet and be handed its
      # org. mppx's push mode calls transferWithMemo directly, so a conforming
      # client always passes.
      signer = receipt["from"] && String.downcase(receipt["from"])

      case Enum.find(matches, &(&1.amount >= expected.amount)) do
        nil when matches == [] -> {:error, :no_matching_transfer}
        nil -> {:error, :underpaid}
        %{from: ^signer} = payment -> {:ok, payment}
        _payment -> {:error, :sender_not_signer}
      end
    end
  end

  defp decode(
         %{"address" => address, "topics" => [topic, from, to, memo], "data" => data},
         expected
       ) do
    with true <- String.downcase(topic) == @transfer_with_memo,
         true <- String.downcase(address) == String.downcase(expected.token),
         true <- address_from_topic(to) == String.downcase(expected.recipient),
         true <- String.downcase(memo) == String.downcase(expected.memo),
         {:ok, amount} <- uint(data) do
      [%{amount: amount, from: address_from_topic(from)}]
    else
      _ -> []
    end
  end

  defp decode(_log, _expected), do: []

  defp address_from_topic("0x" <> hex) when byte_size(hex) == 64,
    do: "0x" <> String.downcase(binary_part(hex, 24, 40))

  defp address_from_topic(_), do: nil

  defp uint("0x" <> hex) when byte_size(hex) > 0 do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp uint(_), do: :error
end
