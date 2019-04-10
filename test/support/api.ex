defmodule TPHelpers.API do

  @resolver TPHelpers.Resolver

  # get current transaction status
  def api_get_tx_status(tx_id, base_url \\ get_base_url()), do: :tpapi.get_tx_status(tx_id, base_url)

  # post encoded and signed transaction using API
  def api_post_transaction(transaction, base_url \\ get_base_url()) do
    :tpapi.commit_transaction(transaction, base_url)
  end

  # get the current seq for wallet
  def api_get_wallet_seq(wallet, base_url \\ get_base_url()) do
    :tpapi.get_wallet_seq(wallet, base_url)
  end

  # get the current blockchain height
  def api_get_height(base_url \\ get_base_url()), do: :tpapi.get_height(base_url)

  # get block headers for the hash
  def api_get_block_info(hash, opts \\ []) do
    :tpapi.get_blockinfo(hash, get_base_url(get_node(opts)))
  end

  defp get_base_url(node \\ nil) do
    @resolver.get_base_url(node)
  end

  defp get_node(opts) do
    Keyword.get(opts, :node, nil)
  end
end
