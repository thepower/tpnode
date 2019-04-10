defmodule TPHelpers.TxGen do
  @moduledoc """
    Provides functions for transaction generation
  """

  def construct_and_sign_tx(from, to, currency, amount, opts \\ []) do
    tx_seq = :os.system_time(:millisecond)
    message = Keyword.get(opts, :message, nil)
    priv_key = Keyword.get(opts, :priv_key, "")

    tx_map =
      %{
        kind: :generic,
        ver: 2,
        t: :os.system_time(:millisecond),
        seq: tx_seq,
        from: :naddress.decode(from),
        to: :naddress.decode(to),
        txext: %{},
        payload: get_tx_payload(amount, currency, opts)
      }

    tx_map =
      if message do
        %{
          tx_map |
          txext: %{
            "message" => message
          }
        }
      else
        tx_map
      end

#    IO.puts("tx_map: #{inspect tx_map}")

    tx = :tx.construct_tx(tx_map)
    :tx.sign(tx, priv_key)
  end

  defp get_tx_payload(amount, currency, opts) do
    fee_amount = Keyword.get(opts, :fee, nil)
    fee_currency = Keyword.get(opts, :fee_currency, "FEE")
    purporse = Keyword.get(opts, :purporse, :transfer)

    fee_term =
      if is_integer(fee_amount) and is_binary(fee_currency) and fee_amount > 0 do
        %{amount: fee_amount, cur: fee_currency, purpose: :srcfee}
      else
        []
      end

    List.flatten(
      [
        %{amount: amount, cur: currency, purpose: purporse},
        fee_term
      ]
    )
  end

end
