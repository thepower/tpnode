# testing plan
# 1. start 2 nodes
# 2. create 10 blocks (to create block we make transaction and wait until it became completed)
# 3. start 3rd node
# 4. get hash of last block from 1st node
# 5. we should get the same hash until the timeout
# 6. create 10 more blocks
# 7. wait until 3rd node get synchronized


Application.ensure_all_started(:inets)

ExUnit.start

{:ok, files} = File.ls("./test/support")

Enum.each files, fn(file) ->
  Code.require_file "support/#{file}", __DIR__
end


defmodule SyncTest do
  use ExUnit.Case, async: false

  import TPHelpers
  import TPHelpers.{API, TxGen}

  # <<128,1,64,0,4,0,0,1>>
  @from_wallet "AA100000006710886518"

  # <<128,1,64,0,4,0,0,2>>
  @to_wallet "AA100000006710886608"

  # currency for transactions
  @currency "SK"

  # chain 4 fee
  @tx_fee 0

  # blocks we need to sync
  @blocks_before_sync 10

  # synchronization waiting timeout in seconds
  @sync_wait_timeout_sec 80

  # default node we send transactions to
  @default_node "c4n1"

  def setup_all do
    for x <- ["c4n1", "c4n2"], do: start_node(x)

    status = ["c4n1", "c4n2"] |> wait_nodes
    logger "nodes status: ~p", [status]

    assert :ok == status

    stop_node("c4n3")

    for x <- [@from_wallet, @to_wallet], do: ensure_wallet_exist(x, node: @default_node)
  end

  def clear_all do
    for x <- ["c4n1", "c4n2", "c4n3"], do: stop_node(x)
  end

  #  @tag :skip
  @tag timeout: 600000
  test "sync test" do
    setup_all()

    initial_height = api_get_height()

    # make blocks
    make_blocks(@blocks_before_sync)

    # get last block hash
    {:ok, %{"block" => %{
      "hash" => block_hash,
      "header" => %{ "height" => height, "parent" => parent_hash}}}}
    = {:ok, block_info}
    = api_get_blockinfo(:last)

    tmp = Map.get(block_info, "temporary", false)

    hash = case tmp do
      false -> block_hash
      _ -> parent_hash
    end

    logger("got block_info: ~p", [block_info])
    logger("hash: ~p, height: ~p, tmp: ~p", [hash, height, tmp])

    # start 3rd node
    start_node("c4n3")
    assert :ok == wait_nodes(["c4n3"])

    # force start synchronization on c4n3
    c4n3_blockchain = :rpc.call(String.to_atom("test_c4n3@pwr"), :erlang, :whereis, [:blockchain])
    send(c4n3_blockchain, :runsync)

    # waiting until the node reach the height after wallets where creation
    :ok = wait_for_height(initial_height, @sync_wait_timeout_sec, node: "c4n3")

    logger("initial height reached")

    before_round1 = :os.system_time(:seconds)
    # wait for block hash on c4n3
    wait_result = wait_for_hash(hash, @sync_wait_timeout_sec, node: "c4n3", height: height)
    after_round1 = :os.system_time(:seconds)

    logger("---------------------------------------------")
    logger("hash wait result: ~p, waited: ~p sec", [wait_result, after_round1 - before_round1])
    logger("---------------------------------------------")

    assert :ok == wait_result

    # make more blocks on c4n1
    make_blocks(@blocks_before_sync)

    {:ok, %{"block" => %{
      "hash" => block_hash2,
      "header" => %{ "height" => height2, "parent" => parent_hash2}}}}
    = {:ok, block_info2}
    = api_get_blockinfo(:last)

    tmp2 = Map.get(block_info2, "temporary", false)

    hash2 = case tmp2 do
      false -> block_hash2
      _ -> parent_hash2
    end

    logger("got block_info2: ~p", [block_info2])
    logger("hash2: ~p, height2: ~p, tmp2: ~p", [hash2, height2, tmp2])

    before_round2 = :os.system_time(:seconds)
    # wait for block hash on c4n3
    wait_result2 = wait_for_hash(hash2, @sync_wait_timeout_sec, node: "c4n3", height: height2)
    after_round2 = :os.system_time(:seconds)

    logger("---------------------------------------------")
    logger("hash2 wait result: ~p, waited: ~p sec", [wait_result2, after_round2 - before_round2])
    logger("---------------------------------------------")

    assert :ok == wait_result2

    clear_all()
  end


  # generate blocks_count transactions and wait each transaction to be included in block
  # so, we instruct blockchain to create at least block_count blocks
  def make_blocks(blocks_count), do: make_blocks(blocks_count, @default_node)
  def make_blocks(blocks_count, node) do
    for block_no <- 1..blocks_count do
      logger("---- making block no: ~p", [block_no])

      tx_id =
        make_transaction(
          @from_wallet,
          @to_wallet,
          @currency,
          block_no,
          fee: @tx_fee,
          message: "sync test tx block #{block_no}}",
          node: node
        )

      logger "sent tx: #{tx_id}"

      {:ok, status, _} = api_get_tx_status(tx_id, node: node)
      logger "api call status: ~p~n", [status]

      assert match?(%{"ok" => true, "res" => "ok"}, status)
    end
  end

  # wait for node until it create a block with the height target_height
  def wait_for_height(target_height, timeout, opts \\ [])
  def wait_for_height(_target_height, 0, _opts), do: :timeout
  def wait_for_height(target_height, timeout, opts) do
    node = Keyword.get(opts, :node, @default_node)

    try do
      case api_get_height(node: node) do
        cur_height when cur_height >= target_height -> :ok
        cur_height ->
          logger("current height: ~p", [cur_height])

          :timer.sleep(1000)
          wait_for_height(target_height, timeout - 1, opts)
      end
    catch
      ec, ee ->
        logger("can't get height for node ~p : ~p:~p", [node, ec, ee])
        :timer.sleep(1000)
        wait_for_height(target_height, timeout - 1, opts)
    end
  end



  # wait for node until it create a block with the hash target_hash
  def wait_for_hash(target_hash, timeout, opts \\ [])
  def wait_for_hash(_target_hash, 0, _opts), do: :timeout
  def wait_for_hash(target_hash, timeout, opts) do
    node = Keyword.get(opts, :node, @default_node)
    height = Keyword.get(opts, :height, nil)

    height_check =
      case height do
        _ when is_number(height) -> # wait for height first
          try do
            case api_get_height(node: node) do
              cur_height when cur_height >= height -> :ok
              cur_height ->
                logger("current height: ~p", [cur_height])
                false
            end
          catch
            ec, ee ->
              logger("can't get height for node ~p : ~p:~p", [node, ec, ee])
              false
          end
        _ -> :ok  # in this case we shouldn't check height, because user didn't ask us for that
      end

    # try to get block with target hash
    result =
      with :ok <- height_check,
           {:ok, block_info} <- api_get_blockinfo(target_hash, node: node) do
        block_info # we've got block info for block with hash target_hash
      else
        _ -> %{} # target hash wasn't found
      end

    case result do
      %{"block" => _} when target_hash == :last -> :ok
      %{"block" => block_info} ->
        case get_perm_hash(block_info) do
          ^target_hash -> :ok
          _ ->
            :timer.sleep(1000)
            wait_for_hash(target_hash, timeout - 1, opts)
        end
      _ ->
        :timer.sleep(1000)
        wait_for_hash(target_hash, timeout - 1, opts)
    end
  end


  # wallet private key settings
  def get_wallet_priv_key(), do: get_wallet_priv_key(@default_node)
  def get_wallet_priv_key(_node) do
    :address.parsekey("5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK")
  end

  # make, encode, sign and post transaction
  def make_transaction(from, to, currency, amount, opts \\ []) do
    node = Keyword.get(opts, :node, @default_node)

    signed_tx = construct_and_sign_tx(
      from,
      to,
      currency,
      amount,
      Keyword.merge(opts, priv_key: get_wallet_priv_key())
    )

    logger("posting tx to node: ~p", [node])

    res = api_post_transaction(:tx.pack(signed_tx), node: node)
    Map.get(res, "txid", :unknown)
  end


  def get_register_wallet_transaction() do
    priv_key = get_wallet_priv_key()
    :tpapi.get_register_wallet_transaction(priv_key, %{promo: "TEST5"})
  end

  # --------------------------------------------------------------------------------
  # register new wallet using API
  def api_register_wallet() do
    register_tx = get_register_wallet_transaction()
    res = api_post_transaction(register_tx)
    tx_id = Map.get(res, "txid", :unknown)
    refute tx_id == :unknown

    {:ok, status, _} = api_get_tx_status(tx_id)
    logger("register wallet transaction status: ~p ~n", [status])

    assert match?(%{"ok" => true}, status)

    wallet = Map.get(status, "res", :unknown)
    refute wallet == :unknown

    logger("new wallet has been registered: ~p ~n", [wallet])
    wallet
  end


  def ensure_wallet_exist(address, opts \\ []) do
    endless_cur = Keyword.get(opts, :endless, false)
    node = Keyword.get(opts, :node, nil)

    # check if wallet exist
    wallet_data =
      unless is_nil(address) do
        case api_get_wallet_info(address, node: node) do
          {:ok, data} -> data
          _ ->
            logger("Wallet isn't exists: ~p", [address])
            nil
        end
      end

    # register new wallet in case of error
    case wallet_data do
      nil ->
        logger("register new wallet, node = ~p", [node])
        wallet_address = api_register_wallet()
        assert address == wallet_address

        case endless_cur do
          false -> :ok
          _ -> make_endless(wallet_address, endless_cur)
        end
      _ -> :ok
    end
  end

  def make_endless(address, currency, opts \\ []) do
    signed_tx = get_tx_make_endless(address, currency, Keyword.take(opts, [:node_key_regex]))
    logger("endless patch tx: ~p~n", [signed_tx])

    res = api_post_transaction(:tx.pack(signed_tx), Keyword.take(opts, [:node]))
    tx_id = Map.get(res, "txid", :unknown)

    {:ok, status, _} = api_get_tx_status(tx_id, Keyword.take(opts, [:node]))
    logger "api call status: ~p~n", [status]

    assert match?(%{"ok" => true, "res" => "ok"}, status)
  end


  
  def wait_nodes(nodes), do: wait_nodes(nodes, 10)
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

end


#SyncTest.start_node "c4n1"
#SyncTest.stop_node "c4n1"
