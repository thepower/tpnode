# Test plan:
# * create endless wallets
# * pre-generate transactions. txs_per_worker transactions for each worker
# * start workers
# * send command start to each worker to get them sending transactions
# * measure tx rate using websockets (see tpnode_ws.erl, search blockstat subscription)


Application.ensure_all_started(:inets)

ExUnit.start

{:ok, files} = File.ls("./test/support")

Enum.each files, fn(file) ->
  Code.require_file "support/#{file}", __DIR__
end


defmodule LoadTest do
  use ExUnit.Case, async: false

  import TPHelpers
  import TPHelpers.API

  # define nodes where send transaction to
  @nodes ["c4n1", "c4n2", "c4n3"]

  # how many transactions should each worker send
  @txs_per_worker 5

  @endless_currency "SK"


  def setup_all do
    for x <- @nodes, do: start_node(x)

    status = @nodes |> wait_nodes
    logger "nodes status: ~p", [status]

    assert :ok == status
  end

  def clear_all do
    for x <- @nodes, do: stop_node(x)
  end

  #  @tag :skip
  @tag timeout: 600000
  test "load test" do
    setup_all()

    # create wallets
    wallets =
      for node <- @nodes do
        logger("register new wallet, node = ~p", [node])

        status = register_wallet(get_wallet_priv_key(), node: node)

        logger("wallet registration status: ~p", [status])
        assert match?(%{"ok" => true}, status)

        wallet_address = Map.get(status, "res", nil)
        refute wallet_address == nil

        logger("new wallet has been registered: ~p", [wallet_address])

        # make endless
        status = make_endless(wallet_address, @endless_currency, node: node)
        assert match?(%{"ok" => true, "res" => "ok"}, status)

        wallet_address
      end

    logger("wallets: ~p", [wallets])
  end

  def get_wallet_priv_key() do
    :address.parsekey("5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK")
  end

end
