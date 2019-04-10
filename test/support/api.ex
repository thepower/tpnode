defmodule TPHelpers.API do

  @resolver TPHelpers.Resolver

  # get current transaction status
  def api_get_tx_status(tx_id, opts \\ []) do
    :tpapi.get_tx_status(tx_id, get_base_url(get_node(opts)))
  end

  # post encoded and signed transaction using API
  def api_post_transaction(transaction, opts \\ []) do
    :tpapi.commit_transaction(transaction, get_base_url(get_node(opts)))
  end

  # get the current seq for wallet
  def api_get_wallet_seq(wallet, opts \\ []) do
    :tpapi.get_wallet_seq(wallet, get_base_url(get_node(opts)))
  end

  # get the current blockchain height
  def api_get_height(opts \\ []), do: :tpapi.get_height(get_base_url(get_node(opts)))

  # get block headers for the hash
  def api_get_block_info(hash, opts \\ []) do
    :tpapi.get_blockinfo(hash, get_base_url(get_node(opts)))
  end

  @spec api_get_wallet_info(binary()|nil, keyword()) :: {:ok, map()} | {:error, any()}
  def api_get_wallet_info(address, opts \\ []) do
    try do
      {:ok, :tpapi.get_wallet_info(address, get_base_url(get_node(opts)))}
    catch
      _ec, ee ->
#        :utils.print_error("error getting wallet data", _ec, ee, :erlang.get_stacktrace())
        {:error, ee}
    end
  end


  @spec api_ping(keyword()) :: boolean()
  def api_ping(opts \\ []) do
    :tpapi.ping(get_base_url(get_node(opts)))
  end

  @spec api_get_blockinfo(binary() | :last, keyword()) :: {:ok, map()} | {:error, binary()}
  def api_get_blockinfo(target_hash, opts \\ []) do
    try do
      res = :tpapi.get_blockinfo(target_hash, get_base_url(get_node(opts)))
      {:ok, res}
    catch
      ec, ee ->
        logger("get blockinfo: ~p:~p~n", [ec, ee])
        {:error, ee}
    end
  end

  defp get_base_url(node) do
    @resolver.get_base_url(node)
  end

  defp get_node(opts) do
    Keyword.get(opts, :node, nil)
  end

  defp logger(fmt, args), do: :utils.logger(to_charlist(fmt), args)
end
