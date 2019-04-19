defmodule TPHelpers.Stat do
  @moduledoc """
    Implements blockchain statistics gathering using websockets
  """

  use GenServer

  alias TPHelpers.StatWrk

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts \\ []) do
    IO.puts("init websockets dispatcher #{inspect opts}")

    Process.flag(:trap_exit, true)

    {
      :ok,
      %{
        workers: [],
        stat_data: %{}
      }
    }
  end

  def handle_call(:state, _from, state) do
    IO.puts("WSD state request")
    {:reply, {:ok, state}, state}
  end

  def handle_call({:connect, host, port}, from, state) do
    handle_call({:connect, host, port, []}, from, state)
  end

  def handle_call({:connect, host, port, opts}, _from, %{workers: wrk} = state) do
    chain = Keyword.get(opts, :chain, 4)
    IO.puts("WSD connecting to [#{chain}] #{inspect host}:#{port}")
    {:ok, wrk_pid} = answer = StatWrk.start_link([host: host, port: port, chain: chain])
    {:reply, answer, %{state | workers: [{wrk_pid, chain} | wrk]}}
  end

  def handle_call(unknown, _from, state) do
    IO.puts("WSD got unknown call: #{inspect unknown}")
    {:reply, :ok, state}
  end

  def handle_cast({:got, from, data}, %{stat_data: stat_data, workers: wrk} = state) do
    new_state =
      with {:ok, timestamp, txs_cnt} <- parse_ws_data(data),
           {^from, chain} <- List.keyfind(wrk, from, 0)
        do
        old_data = Map.get(stat_data, chain, [])
        new_data = Map.put(stat_data, chain, old_data ++ [{timestamp, txs_cnt}])

#        IO.inspect new_data, label: "stat"
        show_stat(new_data)

        %{state | stat_data: new_data}
      else
        _ ->
          IO.puts("** WS can't parse block stat data: #{inspect data}")
          state
      end

    {:noreply, new_state}
  end

  def handle_cast(unknown, state) do
    IO.puts("WSD got unknown cast: #{inspect unknown}")
    {:noreply, state}
  end

  # handle the trapped exit call
  def handle_info({:EXIT, _from, reason}, state) do
    IO.puts "WSD exiting with reason: #{inspect reason}"

    {:stop, reason, state}
  end

  def handle_info({:wrk_up, wrk_pid}, state) do
    IO.puts("WSD worker #{inspect wrk_pid} went up")
    {:noreply, state}
  end

  def handle_info({:wrk_down, wrk_pid, reason}, state) do
    IO.puts "WSD worker #{inspect wrk_pid} went down with reason #{inspect reason}"

    {:noreply, state}
  end

  def handle_info(unknown, state) do
    IO.puts("WSD got unknown info: #{inspect unknown}")
    {:noreply, state}
  end

  def terminate(reason, _state) do
    IO.puts "WSD terminate dispatcher, reason: #{reason}"
    :normal
  end

  defp parse_ws_data(data) do
    try do
      %{
        "blockstat" => %{
          "txs_cnt" => txs_cnt,
          "timestamp" => block_timestamp
        }
      } = :jsx.decode(data, [:return_maps])

      IO.puts "last block tx count: #{inspect txs_cnt} [created at #{inspect block_timestamp}]"

      {:ok, block_timestamp, txs_cnt}
    catch
      ec, ee ->
        :utils.print_error("WSD parse ws data failed", ec, ee, :erlang.get_stacktrace())
        :error
    end
  end

  defp show_stat(data) do
    txs_iterator =
      fn ({ts, tx_cnt}, acc) ->
        pre_ts = Map.get(acc, :pre_ts, ts)
        total_txs_cnt = Map.get(acc, :total_txs_cnt, 0) + tx_cnt
        min_ts = min(Map.get(acc, :min_ts, ts), ts)
        max_ts = max(Map.get(acc, :max_ts, min_ts), ts)

        chain_rate =
          if pre_ts != ts do
            (tx_cnt * 1000) / abs(ts - pre_ts)
          else
            0
          end

        %{
          pre_ts: ts,
          total_txs_cnt: total_txs_cnt,
          min_ts: min_ts,
          max_ts: max_ts,
          chain_rate: chain_rate,
        }
      end

    chain_iterator =
      fn ({chain, txs}, acc) ->
        chain_stat = Enum.reduce(txs, %{}, txs_iterator)

        chain_min_ts = Map.get(chain_stat, :min_ts)
        chain_max_ts = Map.get(chain_stat, :max_ts, chain_min_ts)
        chain_tx_cnt = Map.get(chain_stat, :total_txs_cnt, 0)

        total_chain_stat = Map.get(acc, :chain_stat, %{})
        total_txs_cnt = Map.get(acc, :total_txs_cnt, 0) + chain_tx_cnt
        min_ts = min(Map.get(acc, :min_ts, chain_min_ts), chain_min_ts)
        max_ts = max(Map.get(acc, :max_ts, chain_max_ts), chain_max_ts)

        total_rate =
          if min_ts != max_ts do
            (total_txs_cnt * 1000) / abs(max_ts - min_ts)
          else
            0
          end

        %{
          total_txs_cnt: total_txs_cnt,
          min_ts: min_ts,
          max_ts: max_ts,
          total_rate: total_rate,
          chain_stat: Map.put(total_chain_stat, chain, chain_stat)
        }
      end

    stat = Enum.reduce(data, %{}, chain_iterator)

    total_rate = Map.get(stat, :total_rate, 0)

    IO.puts("\n**")
    IO.puts("*  total rate: #{total_rate}")
    for {chain, chain_stat} <- Map.get(stat, :chain_stat, %{}) do
      chain_rate = Map.get(chain_stat, :chain_rate, 0)
      IO.puts("*  chain [#{chain}] rate: #{chain_rate}")
    end
    IO.puts("**")

#    IO.inspect stat, label: "raw stat"
  end

end
