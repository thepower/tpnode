defmodule TPHelpers do

  alias TPHelpers.Resolver

  import TPHelpers.{API}

  @spec start_node(binary(), keyword()) :: :ok
  def start_node(node, opts \\ []) do
    case is_node_alive?(node) do
      true -> logger("Skiping alive node ~p", [node])
      _ ->
        {:ok, chain_no, _node_no} = Resolver.get_chain_from_node_name(node)

        logger("Starting the node [#{chain_no}]: #{node}")

        dir = Keyword.get(opts, :dir, "./examples/test_chain#{chain_no}")
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
         tx_id when not is_nil(tx_id) <- Map.get(res, "txid", nil)
      do
      IO.puts "wallet registration tx_id: #{tx_id}"

      case api_get_tx_status(tx_id, Keyword.take(opts, [:node])) do
        {:ok, status, _} -> status
        _ -> :error
      end
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

  @spec check_poptxs_all_chains(integer(), list()) :: list()
  def check_poptxs_all_chains(value, nodes) do
    nodes
    |> Enum.map(
         fn (node) ->
           {:ok, chain_no, _} =
             Resolver.get_chain_from_node_name(node)
           chain_no
         end
       )
    |> Enum.uniq
    |> Enum.each(
         fn (chain) ->
           IO.puts("checking settings for chain: #{chain}")
           check_poptxs(value, chain: chain, node_key_regex: ~r/c#{chain}n.+/)
         end
       )
  end

  @spec check_poptxs(integer(), keyword()) :: any()
  def check_poptxs(value, opts \\ []) do
    with %{"ok" => true, "settings" => settings} <-
           api_get_settings(Keyword.take(opts, [:chain])),
         current <- Map.get(settings, "current", %{}),
         chain <- Map.get(current, "chain", %{}),
         current_poptxs <- Map.get(chain, "poptxs", 200)
      do
      if value != current_poptxs do
        logger("current poptxs is ~p, set it to ~p", [current_poptxs, value])
        patch_poptxs(value, opts)
      end
    end
  end

  @spec patch_poptxs(integer(), keyword()) :: any()
  def patch_poptxs(value, opts \\ []) do
    signed_tx = get_tx_patch(
      "set",
      ["current", "chain", "poptxs"],
      value,
      Keyword.take(opts, [:node_key_regex])
    )

    res = api_post_transaction(:tx.pack(signed_tx), Keyword.take(opts, [:node, :chain]))
    tx_id = Map.get(res, "txid", :unknown)

    {:ok, status, _} = api_get_tx_status(tx_id, Keyword.take(opts, [:node, :chain]))
    logger "api call status: ~p", [status]

    status
  end

  @spec push_map_array(map(), any(), any()) :: map()
  def push_map_array(map, key, value) when is_map(map) do
    Map.put(map, key, Map.get(map, key, []) ++ [value])
  end

  @spec pop_map_array(map(), any()) :: {:ok, any(), map()} | {:error, any()}
  def pop_map_array(map, key) when is_map(map) do
    arr = Map.get(map, key, [])

    case Enum.split(arr, 1) do
      {[], []} -> {:error, :array_underrun}
      {member, tail} ->
        {:ok, member, Map.put(map, key, tail)}
    end
  end

  @spec logger(binary(), list()) :: any()
  def logger(format, args \\ []), do: :utils.logger(to_charlist(format), args)

end
