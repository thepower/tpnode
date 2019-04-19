defmodule TPHelpers.TxSender do
  @moduledoc """
    Implements worker, which send transactions via the API.
  """

  use GenServer

  import TPHelpers.API


  def start_link(opts \\ []) do
    #    IO.puts("start link #{inspect opts}")
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts \\ []) do
    name = Keyword.get(opts, :name, :unknown)
    IO.puts("init worker #{name}")

    Process.flag(:trap_exit, true)

    {
      :ok,
      %{
        counter: 0,
        node: Keyword.get(opts, :node, nil),
        txs: Keyword.get(opts, :txs, []),
        name: name,
        mode: :idle,
        tx_ids: []
      }
    }
  end

  def handle_call(:get_count, _from, %{counter: count} = state) do
    {:reply, {:ok, count}, state}
  end

  def handle_call(:get_mode, _from, %{mode: mode} = state) do
    {:reply, {:ok, mode}, state}
  end

  def handle_call(:get_progress, _from, %{mode: mode, counter: sent} = state) do
    {:reply, {:ok, %{mode: mode, sent: sent}}, state}
  end

  def handle_call(:get_tx_ids, _from, %{tx_ids: tx_ids, node: node} = state) do
    {:reply, {:ok, {node, tx_ids}}, state}
  end

  def handle_call(:state, _from, state) do
    IO.puts("state request")
    {:reply, {:ok, state}, state}
  end


  def handle_call(unknown, _from, state) do
    IO.puts("got unknown call: #{inspect unknown}")
    {:reply, :ok, state}
  end

  def handle_cast(:start, %{mode: mode} = state) when mode == :idle do
    IO.puts("start sending transactions")
    GenServer.cast(self(), :send)
    {:noreply, %{state | mode: :working}}
  end

  def handle_cast(:stop, %{mode: mode} = state) when mode == :working do
    IO.puts("stop sending transactions (requested)")
    {:noreply, %{state | mode: :idle}}
  end

  # go to :idle mode if no more transactions left
  def handle_cast(:send, %{mode: mode, txs: []} = state) when mode == :working do
    IO.puts("stop sending transactions (all txs were sent)")
    {:noreply, %{state | mode: :idle}}
  end

  # send one transaction
  def handle_cast(
        :send,
        %{
          mode: mode,
          txs: [tx | tail],
          node: node,
          tx_ids: tx_ids,
          counter: count
        } = state
      ) when mode == :working do

    new_state =
      case send_tx(tx, node) do
        {:ok, tx_id} -> %{state | tx_ids: [tx_id | tx_ids]}
        send_error ->
          IO.puts("transaction send error: #{inspect send_error}")
          state
      end

    GenServer.cast(self(), :send)

    {:noreply, %{new_state | txs: tail, counter: count + 1}}
  end

  def handle_cast(unknown, state) do
    IO.puts("got unknown cast: #{inspect unknown}")
    {:noreply, state}
  end


  # handle the trapped exit call
  def handle_info({:EXIT, _from, reason}, state) do
    IO.puts "exiting"

    {:stop, reason, state}
  end

  def handle_info(:stop_worker, %{name: name} = _state)do
    IO.puts("worker: #{name} going to stop")
    exit(:normal)
  end

  def handle_info(unknown, state) do
    IO.puts("got unknown info: #{inspect unknown}")
    {:noreply, state}
  end


  def terminate(reason, %{name: name}) do
    IO.puts "terminate: #{name}, reason: #{reason}"
    :normal
  end

  defp send_tx(tx, node) do
    try do
      res = api_post_transaction(tx, node: node)
#      IO.puts("raw send: #{inspect res}")
      {:ok, Map.get(res, "txid", {:error, :bad_answer})}
    catch
      ec, ee ->
        :utils.print_error("tx send failed", ec, ee, :erlang.get_stacktrace())
        {:error, ee}
    end
  end

end
