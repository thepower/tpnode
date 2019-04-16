# Test plan:
# * create endless wallets
# * pre-generate transactions. txs_per_worker transactions for each worker
# * start workers
# * send command start to each worker to get them sending transactions
# * measure tx rate using websockets (see tpnode_ws.erl, search blockstat subscription)


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
  @nodes ["c4n1", "c4n2", "c4n3"]

  # how many transactions should each worker send
  @txs_per_worker 1000

  @tx_currency "SK"


  def setup_all do
    for x <- @nodes, do: start_node(x)

    status = wait_nodes(@nodes)

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

    {senders, dests}
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

  defp start_statistics() do
    # start a statistics server
    {:ok, stat_sup_pid} = DynamicSupervisor.start_link(
      [
        name: :stat_keeper,
        strategy: :one_for_one
      ]
    )
    IO.puts("statistics supervisor pid: #{inspect stat_sup_pid}")

    {:ok, stat_disp_pid} = DynamicSupervisor.start_child(
      :stat_keeper,
      %{
        restart: :temporary,
        id: "stat_dispatcher",
        type: :worker,
        start: {Stat, :start_link, []}
      }
    )

    %{"host" => host, "port" => port} = Resolver.get_api_host_and_port()
    {:ok, stat_wrk_pid} =
      GenServer.call(stat_disp_pid, {:connect, to_charlist(host), String.to_integer(port)})

    {:ok, stat_sup_pid, stat_disp_pid, stat_wrk_pid}
  end

  defp send_transactions(wrk_pids) do
    logger("start sending transactions to ~p nodes", [length(@nodes)])

    for wrk_pid <- wrk_pids do
      GenServer.cast(wrk_pid, :start)
    end

    wait_workers(wrk_pids)
    logger("all transactions was sent")
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
          {:ok, {_name, [last_tx_id | _other_tx_ids]}} = GenServer.call(pid, :get_tx_ids)
          [last_tx_id | acc]
        end
      )

    logger("wait for tx ids: ~p", [tx_ids])

    for tx_id <- tx_ids do
      try do
        {:ok, status, _} = api_get_tx_status(tx_id, timeout: 120)
        logger("tx ~p status ~p", [tx_id, status])
      catch
        ec, ee ->
          :utils.print_error("ws worker run failed", ec, ee, :erlang.get_stacktrace())
      end
    end

    logger("wait for txs done")

    :ok
  end


  #  @tag :skip
  @tag timeout: 600000
  test "load test" do
    setup_all()

    # create wallets
    {senders, dests} = create_wallets(
      %{
        endless_cur: @tx_currency,
        nodes: @nodes,
        priv_key: get_wallet_priv_key()
      }
    )

    check_poptxs(50, node_key_regex: ~r/c4n.+/)

    # generate transactions for each worker
    txs =
      generate_txs(
        senders,
        dests,
        nodes: @nodes,
        priv_key: get_wallet_priv_key(),
        txs_per_node: @txs_per_worker
      )
#    logger("txs: ~p", [txs])

    # start transaction send workers
    {:ok, _sup_pid, wrk_pids} = start_workers(%{txs: txs})
    logger("all worker pids: ~p", [wrk_pids])

    {:ok, _stat_sup_pid, _stat_disp_pid, _stat_wrk_pid} = start_statistics()

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


  @spec generate_txs(list(), list(), keyword()) :: map()
  def generate_txs(senders, dests, opts \\ []) do
    nodes = Keyword.get(opts, :nodes, @nodes)
    priv_key = Keyword.get(opts, :priv_key, get_wallet_priv_key())
    tx_count = Keyword.get(opts, :txs_per_node, 10)
    currency = Keyword.get(opts, :currency, @tx_currency)

    {wallets_map, [], []} =
      Enum.reduce(
        nodes,
        {%{}, senders, dests},
        fn (node, {acc, [sender | tail_senders], [dest | tail_dests]}) ->
          {Map.put(acc, node, %{s: sender, d: dest}), tail_senders, tail_dests}
        end
      )

    nodes
    |> Enum.reduce(
         %{},
         fn (node, acc) ->
           %{s: src, d: dst} = Map.get(wallets_map, node)

           txs =
             for tx_no <- 1..tx_count do
               message = "tx #{tx_no}"
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

  @spec register_wallets(keyword()) :: list(binary())
  def register_wallets(opts \\ []) do
    endless = Keyword.get(opts, :endless, false)
    nodes = Keyword.get(opts, :nodes, @nodes)
    priv_key = Keyword.get(opts, :priv_key, get_wallet_priv_key())

    for node <- nodes do
      logger("register new wallet, node = ~p", [node])

      status = register_wallet(priv_key, node: node)

      logger("wallet registration status: ~p", [status])
      assert match?(%{"ok" => true}, status)

      wallet_address = Map.get(status, "res", nil)
      refute wallet_address == nil

      logger("new wallet has been registered: ~p", [wallet_address])

      # make endless
      if is_binary(endless) do
        status = make_endless(wallet_address, endless, node: node, node_key_regex: ~r/c4n.+/)
        assert match?(%{"ok" => true, "res" => "ok"}, status)
      end

      wallet_address
    end
  end

end
