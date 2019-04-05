defmodule TPHelpers.API do

  import TPHelpers.Resolver

  # get current transaction status
  def api_get_tx_status(tx_id), do: api_get_tx_status(tx_id, get_base_url())
  def api_get_tx_status(tx_id, base_url), do: :tpapi.get_tx_status(tx_id, base_url)

  # post encoded and signed transaction using API
  def api_post_transaction(transaction) do
    api_post_transaction(transaction, get_base_url())
  end

  def api_post_transaction(transaction, base_url) do
    :tpapi.commit_transaction(transaction, base_url)
  end

  # get current seq for wallet
  def api_get_wallet_seq(wallet) do
    api_get_wallet_seq(wallet, get_base_url())
  end

  def api_get_wallet_seq(wallet, base_url), do: :tpapi.get_wallet_seq(wallet, base_url)

  # get the blockchain height
  def api_get_height(opts \\ []) do
    api_get_height(get_base_url(Keyword.get(opts, :node, nil)))
  end

  def api_get_height(base_url), do: :tpapi.get_height(base_url)

  # get block headers for the hash
  def api_get_block_info(hash, opts \\ []) do
    :tpapi.get_blockinfo(hash, get_base_url(Keyword.get(opts, :node, nil)))
  end
end