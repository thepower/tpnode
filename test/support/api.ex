defmodule TPHelpers.API do

  @resolver TPHelpers.Resolver

  # get current transaction status
  def api_get_tx_status(tx_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 40)
    :tpapi.get_tx_status(tx_id, get_base_url(get_node(opts), opts), timeout)
  end

  # post encoded and signed transaction using API
  def api_post_transaction(transaction, opts \\ []) do
    :tpapi.commit_transaction(transaction, get_base_url(get_node(opts), opts))
  end

  # get the current seq for wallet
  def api_get_wallet_seq(wallet, opts \\ []) do
    :tpapi.get_wallet_seq(wallet, get_base_url(get_node(opts), opts))
  end

  # get the current blockchain height
  def api_get_height(opts \\ []), do: :tpapi.get_height(get_base_url(get_node(opts), opts))

  # get block headers for the hash
  def api_get_block_info(hash, opts \\ []) do
    :tpapi.get_blockinfo(hash, get_base_url(get_node(opts), opts))
  end

  @spec api_get_block(binary(), keyword()) :: map()
  def api_get_block(hash, opts \\ []) do
    :tpapi.get_block(hash, get_base_url(get_node(opts), opts))
  end


  @spec api_get_settings(keyword()) :: map()
  def api_get_settings(opts \\ []) do
    :tpapi.get_settings(get_base_url(get_node(opts), opts))
  end

  @spec api_get_wallet_info(binary() | nil, keyword()) :: {:ok, map()} | {:error, any()}
  def api_get_wallet_info(address, opts \\ []) do
    try do
      {:ok, :tpapi.get_wallet_info(address, get_base_url(get_node(opts), opts))}
    catch
      _ec, ee ->
        #        :utils.print_error("error getting wallet data", _ec, ee, :erlang.get_stacktrace())
        {:error, ee}
    end
  end

  @spec api_ping(keyword()) :: boolean()
  def api_ping(opts \\ []) do
    :tpapi.ping(get_base_url(get_node(opts), opts))
  end

  @spec api_get_blockinfo(binary() | :last, keyword()) :: {:ok, map()} | {:error, binary()}
  def api_get_blockinfo(target_hash, opts \\ []) do
    try do
      res = :tpapi.get_blockinfo(target_hash, get_base_url(get_node(opts), opts))
      {:ok, res}
    catch
      ec, ee ->
        logger("get blockinfo: ~p:~p~n", [ec, ee])
        {:error, ee}
    end
  end

  @spec sign_patch(map(), list(binary())) :: map()
  def sign_patch(patch_map, node_priv_keys) do
    node_priv_keys
    |> Enum.sort
    |> Enum.reduce(patch_map, fn (key, acc) -> :tx.sign(acc, key) end)
  end

  @spec get_tx_make_endless(binary(), binary(), keyword()) :: map()
  def get_tx_make_endless(wallet, currency, opts \\ []) do
    address = :naddress.decode(wallet)

    get_tx_patch(
      "set",
      [
        "current",
        "endless",
        address,
        currency
      ],
      true,
      opts
    )
  end

  @spec get_tx_patch(binary(), list(), any(), keyword()) :: map()
  def get_tx_patch(type, [_ | _] = path, value, opts \\ []) do
    node_regex = Keyword.get(opts, :node_key_regex, nil)
    priv_keys = @resolver.get_all_priv_keys(node_regex)

    IO.inspect Enum.map(priv_keys, &(:hex.encode(&1))), label: "used node keys for sign patch"

    sign_patch(get_patch(type, path, value), priv_keys)
  end

  @spec get_patch(binary(), list(), any()) :: map()
  def get_patch(type, [_ | _] = path, value) when is_binary(type) do
    :tx.construct_tx(
      %{
        kind: :patch,
        ver: 2,
        patches: [
          %{
            "t" => type,
            "p" => path,
            "v" => value
          }
        ]
      }
    )
  end

  @spec get_base_url(binary(), keyword()) :: binary()
  defp get_base_url(node, opts \\ []) do
    @resolver.get_base_url(node, opts)
  end

  @spec get_node(keyword()) :: binary() | nil
  defp get_node(opts) do
    Keyword.get(opts, :node, nil)
  end

  #  @spec get_node_priv(binary() | nil) :: binary()
  #  defp get_node_priv(node \\ nil) do
  #    @resolver.get_priv_key(node)
  #  end

  defp logger(fmt, args), do: :utils.logger(to_charlist(fmt), args)
end
