# Test plan:
# * create endless wallets
# * pre-generate transactions. txs_per_worker transactions for each worker
# * start workers
# * send command start to each worker to get them sending transactions
# * measure tx rate using websockets (see tpnode_ws.erl, search blockstat subscription)

# TODO: count valid transactions, check invalid transactions using blocks
# (we need to memorize block hashes from websockets information)


Application.ensure_all_started(:inets)

ExUnit.start

{:ok, files} = File.ls("./test/support")

Enum.each files, fn (file) ->
  Code.require_file "support/#{file}", __DIR__
end


defmodule LoadTest do
  use ExUnit.Case, async: false

  alias TPHelpers.{TxSender, Stat, Resolver}

  import TPHelpers
  import TPHelpers.{TxGen, API}


  # define nodes where send transaction to
  @nodes ["c4n1", "c4n2", "c4n3", "c5n1", "c5n2", "c5n3"]
#  @nodes ["c4n1", "c4n2", "c4n3"]

  # how many transactions should each worker send
  @txs_per_worker 1000

  # transaction currency
  @tx_currency "SK"

  # probability of xchain transaction
#  @xchain_ratio 0
  @xchain_ratio 0.20


  @poptx_value 100

  def setup_all do
    for x <- @nodes, do: start_node(x)

    status = wait_nodes(@nodes, 20)

    logger "nodes status: ~p", [status]

    assert :ok == status
  end

  def clear_all do
    #    for x <- @nodes, do: stop_node(x)
    :ok
  end

  defp create_wallets(%{endless_cur: currency, nodes: nodes, priv_key: priv_key}) do
    # create endless sender wallets
    senders =
      register_wallets(endless: currency, nodes: nodes, priv_key: priv_key)
    logger("senders: ~p", [senders])

    # create ordinary wallets which will be used as destinations
    dests = register_wallets(nodes: nodes, priv_key: priv_key)
    logger("destinations: ~p", [dests])

    {:ok, senders, dests}
  end

  defp start_workers(%{txs: txs}) do
    {:ok, sup_pid} = DynamicSupervisor.start_link(
      [
        name: :wrk_keeper,
        strategy: :one_for_one
      ]
    )
    IO.puts("supervisor pid: #{inspect sup_pid}")

    # start transaction send workers
    wrk_pids =
      for node <- @nodes do
        wrk_name = "wrk_#{node}"
        IO.puts("starting worker #{wrk_name}")

        wrk_opts = [
          name: wrk_name,
          node: node,
          txs: Map.get(txs, node)
        ]

        {:ok, pid} = DynamicSupervisor.start_child(
          :wrk_keeper,
          %{
            restart: :temporary,
            id: wrk_name,
            type: :worker,
            start: {TxSender, :start_link, [wrk_opts]}
          }
        )
        IO.puts("worker pid: #{inspect pid}")
        pid
      end

    {:ok, sup_pid, wrk_pids}
  end

  defp start_statistics(nodes) do
    # start a statistics supervisor
    {:ok, stat_sup_pid} = DynamicSupervisor.start_link(
      [
        name: :stat_keeper,
        strategy: :one_for_one
      ]
    )
    IO.puts("statistics supervisor pid: #{inspect stat_sup_pid}")

    # start a dispatcher which collects the satistics
    {:ok, stat_disp_pid} = DynamicSupervisor.start_child(
      :stat_keeper,
      %{
        restart: :temporary,
        id: "stat_dispatcher",
        type: :worker,
        start: {Stat, :start_link, []}
      }
    )

    # connect websockets, one connection to one node for each chain
    wrk_pid_map = connect_websockets(stat_disp_pid, nodes)

    {:ok, stat_sup_pid, stat_disp_pid, wrk_pid_map}
  end

  @spec connect_websockets(pid(), list()) :: map()
  defp connect_websockets(stat_disp_pid, nodes) do
    # make only one connection to each chain
    nodes
    |> Enum.reduce(
         %{},
         fn (node_name, acc) ->
           {:ok, chain_no, _node_no} = Resolver.get_chain_from_node_name(node_name)
           case Map.get(acc, chain_no, nil) do
             nil ->
               # we haven't connetion to nodes of that chain yet. doing it now.
               with {:ok, host, port} <- Resolver.get_api_host_and_port(node_name),
                    {:ok, stat_wrk_pid} <-
                      GenServer.call(
                        stat_disp_pid,
                        {:connect, host, port, chain: chain_no}
                      )
                 do
                 Map.put(acc, chain_no, stat_wrk_pid)
               else
                 _ -> acc
               end
             _ ->
               # skip that node, we already have a connection to that chain
               acc
           end
         end
       )
    |> Enum.reduce(%{}, fn ({key, val}, acc) -> Map.put(acc, val, key) end)
  end

  defp send_transactions(wrk_pids) do
    logger("start sending transactions to ~p nodes", [length(@nodes)])

    for wrk_pid <- wrk_pids do
      GenServer.cast(wrk_pid, :start)
    end

    wait_workers(wrk_pids)
    logger("all transactions were sent")
    :ok
  end

  defp wait_txs(wrk_pids) do
    logger("waiting until the transactions will be committed")

    # get last tx id for each worker
    tx_ids =
      Enum.reduce(
        wrk_pids,
        [],
        fn (pid, acc) ->
          {:ok, {node, [last_tx_id | _other_tx_ids]}} = GenServer.call(pid, :get_tx_ids)
          [{node, last_tx_id} | acc]
        end
      )

    logger("wait for tx ids: ~p", [tx_ids])

    for {node, tx_id} <- tx_ids do
      try do
        {:ok, status, _} = api_get_tx_status(tx_id, node: node, timeout: 120)
        logger("tx ~p [~p] status ~p", [tx_id, node, status])
      catch
        ec, ee ->
          :utils.print_error(
            "can't get transaction #{tx_id} status from #{node}",
            ec,
            ee,
            :erlang.get_stacktrace()
          )
      end
    end

    logger("wait for txs done")

    :ok
  end


  #  @tag :skip
  @tag timeout: 600000
  test "load test" do
    IO.puts "starting a load test"
    setup_all()

    # check chain settings
    check_poptxs_all_chains(@poptx_value, @nodes)

    # create wallets
    {:ok, senders, dests} = create_wallets(
      %{
        endless_cur: @tx_currency,
        nodes: @nodes,
        priv_key: get_wallet_priv_key()
      }
    )

    # generate transactions for each worker
    txs =
      generate_txs(
        senders,
        dests,
        nodes: @nodes,
        priv_key: get_wallet_priv_key(),
        txs_per_node: @txs_per_worker,
        xchain_ratio: @xchain_ratio
      )

    #    logger("txs: ~p", [txs])

    # start transaction send workers
    {:ok, _sup_pid, wrk_pids} = start_workers(%{txs: txs})
    logger("all worker pids: ~p", [wrk_pids])

    {:ok, _stat_sup_pid, _stat_disp_pid, _wrk_pid_map} = start_statistics(@nodes)

    :timer.sleep(5_000)

    # let's the show begin
    send_transactions(wrk_pids)

    # waiting until last transaction be committed
    wait_txs(wrk_pids)

    logger("clean up")

    res = DynamicSupervisor.stop(:stat_keeper)
    IO.puts("stop the statistics: #{inspect res}")

    res = DynamicSupervisor.stop(:wrk_keeper)
    IO.puts("stop the supervisor: #{inspect res}")

    clear_all()
  end

  def wait_workers(wrk_pids) do
    workers_state =
      wrk_pids
      |> Enum.map(
           fn (wrk_pid) ->
             {:ok, %{mode: mode, sent: sent}} = GenServer.call(wrk_pid, :get_progress)
             if mode == :working do
               {wrk_pid, sent}
             end
           end
         )
      |> Enum.filter(&(&1))

    logger("workers state: ~p", [workers_state])

    if length(workers_state) > 0 do
      :timer.sleep(1000)
      wait_workers(wrk_pids)
    end
  end


  def choose_dest_wallet(dest_map, our_chain, xchain_dest) do
    # choose a destination wallet from our chain or from any other chains in case of xchain
    all_chains = Map.keys(dest_map)

    dest_chain =
      if xchain_dest do
        List.delete(all_chains, our_chain)
        |> Enum.random
      else
        true = Enum.member?(all_chains, our_chain)
        our_chain
      end

    Map.get(dest_map, dest_chain)
    |> Enum.random
  end


  @spec generate_txs(map(), map(), keyword()) :: map()
  def generate_txs(sender_map, dest_map, opts \\ []) do
    nodes = Keyword.get(opts, :nodes, @nodes)
    priv_key = Keyword.get(opts, :priv_key, get_wallet_priv_key())
    tx_count = Keyword.get(opts, :txs_per_node, 10)
    currency = Keyword.get(opts, :currency, @tx_currency)
    xchain_ratio = Keyword.get(opts, :xchain_ratio, 0)

    # assign a source wallet to each node
    {node_settings, _} =
      nodes
      |> Enum.reduce(
           {%{}, sender_map},
           fn (node, {settings, senders}) ->
             # get chain from node name
             {:ok, chain, _} = Resolver.get_chain_from_node_name(node)

             # get source address from that chain
             {:ok, wallet, new_senders} = pop_map_array(senders, chain)

             {Map.put(settings, node, %{src: wallet, chain: chain}), new_senders}
           end
         )

    # generate txs for each node
    Enum.reduce(
      node_settings,
      %{},
      fn ({node, %{src: src, chain: our_chain}}, acc) ->
        txs =
          for tx_no <- 1..tx_count do
            # decide which type of transaction we want
            # (intrachain transaction or xchain)
            xchain = :rand.uniform() < xchain_ratio

            # get destination wallet
            dst = choose_dest_wallet(dest_map, our_chain, xchain)

            message =
              if xchain do
                "xchain tx #{tx_no} from #{our_chain}"
              else
                "tx #{tx_no}"
              end

            amount = tx_no

            :tx.pack(
              construct_and_sign_tx(
                src,
                dst,
                currency,
                amount,
                message: message,
                priv_key: priv_key
              )
            )
          end
        Map.put(acc, node, txs)
      end
    )
  end

  @spec get_wallet_priv_key() :: binary()
  def get_wallet_priv_key() do
    :address.parsekey("5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK")
  end

  # TODO: get chain from wallet address, not from node name
  # return: %{4 => ["addr1", "addr2", "addr3"], 5 => ["addr1", "addr2", "addr3"]}
  @spec register_wallets(keyword()) :: map()
  def register_wallets(opts \\ []) do
    endless = Keyword.get(opts, :endless, false)
    nodes = Keyword.get(opts, :nodes, @nodes)
    priv_key = Keyword.get(opts, :priv_key, get_wallet_priv_key())

    for node <- nodes do
      {:ok, chain_no, _node_no} = Resolver.get_chain_from_node_name(node)

      logger("register new wallet, node = ~p [chain: ~p]", [node, chain_no])

      status = register_wallet(priv_key, node: node)

      logger("wallet registration status: ~p", [status])
      assert match?(%{"ok" => true}, status)

      wallet_address = Map.get(status, "res", nil)
      refute wallet_address == nil

      logger("new wallet has been registered [~p]: ~p", [chain_no, wallet_address])

      # make endless
      if is_binary(endless) do
        status =
          make_endless(
            wallet_address,
            endless,
            node: node,
            node_key_regex: ~r/c#{chain_no}n.+/
          )
        assert match?(%{"ok" => true, "res" => "ok"}, status)
      end

      {chain_no, wallet_address}
    end
    |> Enum.reduce(%{}, fn ({chain, address}, acc) -> push_map_array(acc, chain, address) end)
  end
end
