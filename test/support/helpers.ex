defmodule TPHelpers do

  import TPHelpers.API

  @spec start_node(binary(), keyword()) :: :ok
  def start_node(node, opts \\ []) do
    case is_node_alive?(node) do
      true -> logger("Skiping alive node ~p", [node])
      _ ->
        logger("Starting the node #{node}")

        dir = Keyword.get(opts, :dir, "./examples/test_chain4")
        bin_dirs_wildcard = Keyword.get(opts, :bin_dirs, "_build/test/lib/*/ebin/")

        bindirs = Path.wildcard(bin_dirs_wildcard)

        exec_args =
          ["-config", "#{dir}/test_#{node}.config", "-sname", "test_#{node}", "-noshell"] ++
          Enum.reduce(bindirs, [], fn x, acc -> ["-pa", x | acc] end) ++
          ["-detached", "+SDcpu", "2:2:", "-s", "lager", "-s", "tpnode"]

        System.put_env("TPNODE_RESTORE", dir)

        result = System.cmd("erl", exec_args)
        logger("result: ~p", [result])
    end

    :ok
  end


  @spec stop_node(binary()) :: :error | :ok
  def stop_node(node) do
    case is_node_alive?(node) do
      false ->
        logger("node #{node} is already down")
        :error
      _ ->
        logger("Stopping the node #{node}")
        result = :rpc.call(String.to_atom("test_#{node}@pwr"), :init, :stop, [])
        logger("result: ~p", [result])
        result
    end
  end


  @spec get_perm_hash(map()) :: binary()
  def get_perm_hash(block_info) when is_map(block_info) do
    block_hash = Map.get(block_info, "hash", nil)
    header = Map.get(block_info, "header", %{})
    parent_hash = Map.get(header, "parent", nil)

    case Map.get(block_info, "temporary", false) do
      false -> block_hash
      _ -> parent_hash
    end
  end


  @spec is_node_alive?(binary(), keyword()) :: boolean()
  def is_node_alive?(node, opts \\ []) do
    host = Keyword.get(opts, :node, 'pwr')
    node_prefix = Keyword.get(opts, :node_prefix, 'test_')
    case :erl_epmd.port_please('#{node_prefix}#{node}', host) do
      {:port, _, _} -> true
      _ -> false
    end
  end


  @spec is_node_functioning?(binary()) :: :ok | {:error, binary()}
  def is_node_functioning?(node) do
    try do
      case api_ping(node: node) do
        true ->
          :ok
        _ ->
          {:error, "node is down"}
      end
    catch
      ec, ee ->
        logger("node #{node} answer: ~p:~1000p", [ec, ee])

        {:error, ee}
    end
  end


  @spec make_endless(binary(), binary(), keyword()) :: map()
  def make_endless(address, currency, opts \\ []) do
    logger("make wallet ~p endless for currency ~p", [address, currency])
    signed_tx = get_tx_make_endless(address, currency, Keyword.take(opts, [:node_key_regex]))

    res = api_post_transaction(:tx.pack(signed_tx), Keyword.take(opts, [:node]))
    tx_id = Map.get(res, "txid", :unknown)

    {:ok, status, _} = api_get_tx_status(tx_id, Keyword.take(opts, [:node]))
    logger "api call status: ~p", [status]

    status
  end

  @spec register_wallet(binary(), keyword()) :: map()
  def register_wallet(priv_key, opts \\ []) do
    extra_data = Keyword.get(opts, :extra, %{promo: "TEST5"})

    with register_tx <- :tpapi.get_register_wallet_transaction(priv_key, extra_data),
         res when is_map(res) <- api_post_transaction(register_tx, Keyword.take(opts, [:node])),
         tx_id when not is_nil(tx_id) <- Map.get(res, "txid", nil),
         {:ok, status, _} <- api_get_tx_status(tx_id)
      do
        status
    end
  end


  @spec wait_nodes(list(), integer()) :: :ok | :timeout
  def wait_nodes(nodes, timeout \\ 10)
  def wait_nodes([], _timeout), do: :ok
  def wait_nodes(_, 0), do: :timeout
  def wait_nodes([node | tail] = nodes, timeout) do
    case is_node_alive?(node) do
      false ->
        :timer.sleep(1000)
        wait_nodes(nodes, timeout - 1)
      _ ->
        case is_node_functioning?(node) do
          :ok ->
            wait_nodes(tail, timeout)
          _ ->
            :timer.sleep(1000)
            wait_nodes(nodes, timeout - 1)
        end
    end
  end


  @spec logger(binary(), list()) :: any()
  def logger(format, args \\ []), do: :utils.logger(to_charlist(format), args)

end
