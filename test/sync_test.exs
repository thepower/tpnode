# testing plan
# 1. start 2 nodes
# 2. make transaction, wait until it became completed
# 3. starting one more node
# 4. get hash of last block from 1st node
# 5. we should get the same hash from 3rd node until the timeout

# TODO:
# * make a little more transactions to c4n1
# * wait untile the c4n3 node became synchronized

Application.ensure_all_started(:inets)

ExUnit.start

{:ok, files} = File.ls("./test/support")

Enum.each files, fn(file) ->
  Code.require_file "support/#{file}", __DIR__
end


defmodule SyncTest do
  use ExUnit.Case, async: false


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

    for x <- [@from_wallet, @to_wallet], do: ensure_wallet_exist(x)
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
    %{"block" => %{
      "hash" => block_hash,
      "header" => %{ "height" => height, "parent" => parent_hash}}}
    = block_info
    = get_block_info(:last, [node: @default_node])

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

    # waiting until the node reach the height after wallets where creation
    :ok = wait_for_height(initial_height, @sync_wait_timeout_sec, node: "c4n3")

    before_round1 = :os.system_time(:seconds)

    # wait for block hash on c4n3
    wait_result = wait_for_hash(hash, @sync_wait_timeout_sec, node: "c4n3", height: height)

    after_round1 = :os.system_time(:seconds)

    logger("hash wait result: ~p, waited: ~p sec", [wait_result, after_round1 - before_round1])
    assert :ok == wait_result

    # make more blocks on c4n1
    make_blocks(@blocks_before_sync)

    %{"block" => %{
      "hash" => block_hash2,
      "header" => %{ "height" => height2, "parent" => parent_hash2}}}
    = block_info2
    = get_block_info(:last, [node: @default_node])

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

    logger("hash2 wait result: ~p, waited: ~p", [wait_result2, after_round2 - before_round2])
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
          @from_wallet, @to_wallet, @currency, block_no,
          @tx_fee, "sync test tx", node: node)

      logger "sent tx: #{tx_id}"

      {:ok, status, _} = api_get_tx_status(tx_id, get_base_url(node))
      logger "api call status: ~p~n", [status]

      assert match?(%{"ok" => true, "res" => "ok"}, status)
    end
  end

  def get_block_info(hash, opts \\ []) do
    node = Keyword.get(opts, :node, @default_node)

    :tpapi.get_blockinfo(hash, get_base_url(node))
  end

  # get the blockchain height
  def api_get_height(), do: api_get_height(get_base_url(@default_node))
  def api_get_height(base_url), do: :tpapi.get_height(base_url)

  # wait for node until it create a block with the height target_height
  def wait_for_height(target_height, timeout, opts \\ [])
  def wait_for_height(_target_height, 0, _opts), do: :timeout
  def wait_for_height(target_height, timeout, opts) do
    node = Keyword.get(opts, :node, @default_node)

    try do
      case api_get_height(get_base_url(node)) do
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
            case api_get_height(get_base_url(node)) do
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
      case height_check do
        :ok ->
          try do
            :tpapi.get_blockinfo(target_hash, get_base_url(node))
          catch
            ec, ee ->
              logger("get blockinfo: ~p:~p~n", [ec, ee])
              false
          end
        _ -> %{} # we didn't reach the target height yet
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

  def get_perm_hash(block_info) when is_map(block_info) do
    block_hash = Map.get(block_info, "hash", nil)
    header = Map.get(block_info, "header", %{})
    parent_hash = Map.get(header, "parent", nil)

    case Map.get(block_info, "temporary", false) do
      false -> block_hash
      _ -> parent_hash
    end
  end


  def stop_node(node) do
    case TPHelpers.is_node_alive?(node) do
      false -> logger("node #{node} is already down")
      _ ->
        logger("Stopping the node #{node}")
        result = :rpc.call(String.to_atom("test_#{node}@pwr"), :init, :stop, [])
        logger("result: ~p", [result])
    end
  end


  def start_node(node) do
    case TPHelpers.is_node_alive?(node) do
      true -> IO.puts "Skiping alive node #{node}"
      _ ->
        IO.puts("Starting the node #{node}")

        dir = "./examples/test_chain4"

        bindirs = Path.wildcard("_build/test/lib/*/ebin/")

        exec_args =
          ["-config", "#{dir}/test_#{node}.config", "-sname", "test_#{node}", "-noshell"] ++
          Enum.reduce(bindirs, [], fn x, acc -> ["-pa", x | acc] end) ++
          ["-detached", "+SDcpu", "2:2:", "-s", "lager", "-s", "tpnode"]

        System.put_env("TPNODE_RESTORE", dir)

        result = System.cmd("erl", exec_args)
        logger "result: ~p", [result]
    end

    :ok
  end

  def get_base_url(node \\ @default_node) do
    nodes_map = %{
      "c4n1" => "http://pwr.local:49841",
      "c4n2" => "http://pwr.local:49842",
      "c4n3" => "http://pwr.local:49843",
      "c5n1" => "http://pwr.local:49851",
      "c5n2" => "http://pwr.local:49852",
      "c5n3" => "http://pwr.local:49853",
      "c6n1" => "http://pwr.local:49861",
      "c6n2" => "http://pwr.local:49862",
      "c6n3" => "http://pwr.local:49863"
    }

     url =
       case :os.getenv("API_BASE_URL", nil) do
         nil -> Map.get(nodes_map, node)
         url_from_env -> url_from_env
       end

     to_charlist(url)
  end

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


  # wallet private key settings
  def get_wallet_priv_key(), do: get_wallet_priv_key(@default_node)
  def get_wallet_priv_key(_node) do
    :address.parsekey("5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK")
  end

  # get current seq for wallet
  def api_get_wallet_seq(wallet), do: api_get_wallet_seq(wallet, get_base_url())
  def api_get_wallet_seq(wallet, base_url), do: :tpapi.get_wallet_seq(wallet, base_url)


  # make, encode, sign and post transaction
  def make_transaction(from, to, currency, amount, _fee, message, opts \\ []) do
    node = Keyword.get(opts, :node, @default_node)
    logger("posting tx to node: ~p", [node])

    seq = api_get_wallet_seq(from, get_base_url(node))
    tx_seq = max(seq, :os.system_time(:millisecond))
    logger("seq for wallet ~p is ~p, use ~p for transaction ~n", [from, seq, tx_seq])
    tx = :tx.construct_tx(
      %{
        kind: :generic,
        ver: 2,
        t: :os.system_time(:millisecond),
        seq: tx_seq,
        from: :naddress.decode(from),
        to: :naddress.decode(to),
        txext: %{
          "message" => message
        },
        payload: [%{amount: amount, cur: currency, purpose: :transfer}]
      }
    )
    signed_tx = :tx.sign(tx, get_wallet_priv_key())
    res = api_post_transaction(:tx.pack(signed_tx), get_base_url(node))
    Map.get(res, "txid", :unknown)
  end

  def logger(format), do: logger(format, [])

  def logger(format, args) do
    :utils.logger(to_charlist(format), args)
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


  def ensure_wallet_exist(address), do: ensure_wallet_exist(address, false)

  def ensure_wallet_exist(address, endless_cur) do
    # check existing
    wallet_data =
      try do
        :tpapi.get_wallet_info(address, get_base_url())
      catch
        ec, ee ->
          :utils.print_error("error getting wallet data", ec, ee, :erlang.get_stacktrace())
          logger("Wallet not exists: ~p", [address])
          nil
      end

    # register new wallet in case of error

    case wallet_data do
      nil ->
        logger("register new wallet, base_url = ~p", [get_base_url()])
        wallet_address = api_register_wallet()
        assert address == wallet_address

        case endless_cur do
          false -> :ok
          _ -> make_endless(address, endless_cur)
        end
      _ -> :ok
    end
  end

  def make_endless(address, cur) do
    patch =
      sign_patchv2(
        :tx.construct_tx(
          %{
            kind: :patch,
            ver: 2,
            patches: [
              %{
                "t" => "set",
                "p" => [
                  "current",
                  "endless",
                  address,
                  cur
                ],
                "v" => true
              }
            ]

          }
        ),
        './examples/test_chain4/c4n?.conf'
      )
    logger("PK ~p~n", [:tx.verify(patch)])
  end


  def sign_patchv2(patch), do: sign_patchv2(patch, 'c4*.config')

  def sign_patchv2(patch, wildcard) do
    priv_keys = :lists.usort(get_all_nodes_keys(wildcard))
    :lists.foldl(
      fn (key, acc) ->
        :tx.sign(acc, key)
      end,
      patch,
      priv_keys
    )
  end

  def get_all_nodes_keys(wildcard) do
    :lists.filtermap(
      fn (filename) ->
        try do
          {:ok, e} = :file.consult(filename)
          case :proplists.get_value(:privkey, e) do
            :undefined -> false
            val -> {true, :hex.decode(val)}

          end
        catch
          _, _ -> false
        end
      end,
      :filelib.wildcard(wildcard)
    )
  end

  def is_node_functioning?(node) do
    try do
      :tpapi.ping(get_base_url(node))
    catch
      ec, ee ->
        logger("node #{node} answer: ~p:~1000p", [ec, ee])
        false
    end
  end

  def wait_nodes(nodes), do: wait_nodes(nodes, 10)
  def wait_nodes([], _timeout), do: :ok
  def wait_nodes(_, 0), do: :timeout

  def wait_nodes([node | tail] = nodes, timeout) do
    case TPHelpers.is_node_alive?(node) do
      false ->
        :timer.sleep(1000)
        wait_nodes(nodes, timeout - 1)
      _ ->
        case is_node_functioning?(node) do
          false ->
            :timer.sleep(1000)
            wait_nodes(nodes, timeout - 1)
          _ ->
            wait_nodes(tail, timeout)
        end
    end
  end

end


#SyncTest.start_node "c4n1"
#SyncTest.stop_node "c4n1"
