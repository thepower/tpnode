# testing plan
# 1. start 2 nodes
# 2. make transaction, wait until it became completed
# 3. starting one more node
# 4. get hash of last block from 1st node
# 5. we should get the same hash from 3rd node until the timeout



Application.ensure_all_started(:inets)

ExUnit.start()

defmodule AssertionTest do
  use ExUnit.Case, async: false

  # <<128,1,64,0,4,0,0,1>>
  @from_wallet "AA100000006710886518"

  # <<128,1,64,0,4,0,0,2>>
  @to_wallet "AA100000006710886608"

  # currency for transactions
  @currency "SK"

  # chain 4 fee
  @tx_fee 0


  #  @tag :skip
  test "sync test" do
    start_node "c4n1"
    start_node "c4n2"

    wait_nodes(["c4n1", "c4n2"])

    ensure_wallet_exist @from_wallet
    ensure_wallet_exist @to_wallet

    tx_id =
      make_transaction(@from_wallet, @to_wallet, @currency, 10, @tx_fee, "sync test tx")

    logger "sent tx: #{tx_id}"

    {:ok, status, _} = api_get_tx_status(tx_id)
    logger "api call status: ~p~n", [status]

    assert match?(%{"ok" => true, "res" => "ok"}, status)
  end


  def start_node(node) do
    case is_node_alive?(node) do
      true -> IO.puts "Skiping alive node #{node}"
      _ ->
        :io.format("Starting the node ~p~n", [node])

        dir = "examples/test_chain4"

        exec_str =
          "erl -config '#{dir}/#{node}.config' -sname #{node} -detached " <>
          "-noshell -pa _build/test/lib/*/ebin +SDcpu 2:2: -s lager -s tpnode"

        :io.format("the run_string is:~n~p~n", [exec_str])
        :os.cmd(exec_str)
    end

    :ok
  end

  def get_base_url do
    to_charlist :os.getenv("API_BASE_URL", "http://pwr.local:49841")
  end

  def api_get_tx_status(tx_id) do
    :tpapi.get_tx_status(tx_id, get_base_url())
  end

  # post encoded and signed transaction using API
  def api_post_transaction(transaction) do
    :tpapi.commit_transaction(transaction, get_base_url())
  end

  def is_node_alive?(node) do
    case :erl_epmd.port_please(:erlang.binary_to_list("test_#{node}"), 'pwr') do
      {:port, _, _} -> true
      _ -> false
    end
  end

  def get_wallet_priv_key() do
    :address.parsekey("5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK")
  end

  def api_get_wallet_seq(wallet), do: :tpapi.get_wallet_seq(wallet, get_base_url())

  def make_transaction(from, to, currency, amount, _fee, message) do
    seq = api_get_wallet_seq(from)
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
    res = api_post_transaction(:tx.pack(signed_tx))
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


  def wait_nodes(_nodes) do
    :ok
  end

end
