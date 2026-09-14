defmodule Lei.Tempo.TransferTest do
  @moduledoc """
  Matching a transfer to its challenge, against real receipts.

  The fixtures are receipts of three transfers made on Tempo testnet while
  building #144, fetched from the public RPC -- not hand-written, because a
  hand-written log encodes what we believe the layout is, and the layout is the
  thing under test. Sandbox Stripe verified the first and declined the second.
  """
  use ExUnit.Case, async: true

  alias Lei.Tempo.Transfer

  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"
  @pathusd "0x20c0000000000000000000000000000000000000"
  @memo "0xc09702f8182f5d94a23d75cc4c2e9835510fde10de3f5e6f20f2387b799f1ef0"
  @payer "0x95b01240addf561daa31b76b1e8f89f8c4287917"
  @memo_topic Transfer.transfer_with_memo_topic()

  defp receipt(name) do
    Path.join([__DIR__, "..", "..", "fixtures", "tempo", "#{name}.json"])
    |> File.read!()
    |> Poison.decode!()
  end

  defp expected(overrides \\ %{}) do
    Map.merge(%{token: @pathusd, recipient: @deposit, memo: @memo, amount: 500_000}, overrides)
  end

  test "a transfer carrying the memo, to our address, in our token, matches" do
    assert {:ok, %{amount: 500_000, from: @payer}} =
             Transfer.find_payment(receipt("memo_to_deposit"), expected())
  end

  test "the plain Transfer log and the fee transfer beside it do not count" do
    # The receipt holds three logs. Only TransferWithMemo can bind to a
    # challenge; a matcher reading Transfer would accept any payment.
    logs = receipt("memo_to_deposit")["logs"]
    assert length(logs) == 3

    only_plain =
      receipt("memo_to_deposit")
      |> Map.update!("logs", fn logs ->
        Enum.reject(logs, &(hd(&1["topics"]) == Transfer.transfer_with_memo_topic()))
      end)

    assert {:error, :no_matching_transfer} = Transfer.find_payment(only_plain, expected())
  end

  test "only TransferWithMemo counts, not another event with the same shape" do
    # Plain Transfer logs have three topics and fall out on shape alone, so
    # they cannot show the signature check is doing anything. A four-topic log
    # from the same token, identical but for its event signature, can.
    lookalike =
      receipt("memo_to_deposit")
      |> Map.update!("logs", fn logs ->
        Enum.map(logs, fn log ->
          case log["topics"] do
            [@memo_topic | rest] ->
              %{log | "topics" => ["0x" <> String.duplicate("ee", 32) | rest]}

            _ ->
              log
          end
        end)
      end)

    assert {:error, :no_matching_transfer} = Transfer.find_payment(lookalike, expected())
  end

  test "a transfer with no memo binds to no challenge, even to our address" do
    assert {:error, :no_matching_transfer} =
             Transfer.find_payment(receipt("nomemo_to_deposit"), expected())
  end

  test "someone else's challenge memo does not match" do
    # The hash-stealing case: a real payment to us, for a different challenge.
    other = "0x" <> String.duplicate("11", 32)

    assert {:error, :no_matching_transfer} =
             Transfer.find_payment(receipt("memo_to_deposit"), expected(%{memo: other}))
  end

  test "a transfer to another address does not match" do
    assert {:error, :no_matching_transfer} =
             Transfer.find_payment(receipt("to_other_address"), expected())

    assert {:error, :no_matching_transfer} =
             Transfer.find_payment(
               receipt("memo_to_deposit"),
               expected(%{recipient: "0x000000000000000000000000000000000000dead"})
             )
  end

  test "a look-alike token does not match" do
    usdc_e = "0x20c000000000000000000000b9537d11c60e8b50"

    assert {:error, :no_matching_transfer} =
             Transfer.find_payment(receipt("memo_to_deposit"), expected(%{token: usdc_e}))
  end

  test "less than asked is underpaid" do
    assert {:error, :underpaid} =
             Transfer.find_payment(receipt("memo_to_deposit"), expected(%{amount: 500_001}))
  end

  test "a reverted transaction pays nothing, whatever its logs say" do
    reverted = Map.put(receipt("memo_to_deposit"), "status", "0x0")
    assert {:error, :transaction_failed} = Transfer.find_payment(reverted, expected())
  end

  test "comparisons ignore hex case" do
    assert {:ok, _} =
             Transfer.find_payment(
               receipt("memo_to_deposit"),
               expected(%{
                 recipient: String.upcase(@deposit) |> String.replace("0X", "0x"),
                 memo: String.upcase(@memo) |> String.replace("0X", "0x")
               })
             )
  end
end
