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
        mode: :idle,
        stat_data: []
      }
    }
  end

  def handle_call(:state, _from, state) do
    IO.puts("state request")
    {:reply, {:ok, state}, state}
  end

  def handle_call({:connect, host, port}, _from, state) do
    IO.puts("connecting to #{inspect host}:#{port}")
    {:ok, _pid} = answer = StatWrk.start_link([host: host, port: port])
    {:reply, answer, %{state | mode: :connect}}
  end

  def handle_call(unknown, _from, state) do
    IO.puts("got unknown call: #{inspect unknown}")
    {:reply, :ok, state}
  end

  def handle_cast({:got, data}, %{stat_data: stat_data} = state) do
    new_state =
      case parse_ws_data(data) do
        {:ok, timestamp, txs_cnt} ->
          %{state | stat_data: stat_data ++ [{timestamp, txs_cnt}]}
        _ -> state
      end

    show_stat(new_state.stat_data)

    {:noreply, new_state}
  end

  def handle_cast(unknown, state) do
    IO.puts("got unknown cast: #{inspect unknown}")
    {:noreply, state}
  end

  # handle the trapped exit call
  def handle_info({:EXIT, _from, reason}, state) do
    IO.puts "exiting with reason: #{inspect reason}"

    {:stop, reason, state}
  end

  def handle_info({:wrk_down, wrk_pid, reason}, state) do
    IO.puts "worker #{inspect wrk_pid} went down with reason #{inspect reason}"

    {:noreply, %{state | mode: :idle}}
  end

  def handle_info(unknown, state) do
    IO.puts("got unknown info: #{inspect unknown}")
    {:noreply, state}
  end


  def terminate(reason, _state) do
    IO.puts "terminate dispatcher, reason: #{reason}"
    :normal
  end

  defp parse_ws_data(data) do
    try do
      json = :jsx.decode(data, [:return_maps])
#      IO.puts "got ws: #{inspect json}"
      %{
        "blockstat" => %{
          "txs_cnt" => txs_cnt,
          "timestamp" => block_timestamp
        }
      } = json
      IO.puts "txs count: #{inspect block_timestamp} : #{inspect txs_cnt}"
      {:ok, block_timestamp, txs_cnt}
    catch
      ec, ee ->
        :utils.print_error("parse ws data failed", ec, ee, :erlang.get_stacktrace())
        :error
    end
  end

  defp show_stat(data) do
    stat_fun =
      fn ({ts, tx_cnt}, acc) ->
        pre_ts = Map.get(acc, :pre_ts, ts)
        total_txs_cnt = Map.get(acc, :total_txs_cnt, 0) + tx_cnt
        min_ts = min(Map.get(acc, :min_ts, ts), ts)
        max_ts = max(Map.get(acc, :max_ts, ts), ts)

        last_rate =
          if pre_ts != ts do
            (tx_cnt * 1000) / abs(ts - pre_ts)
          else
            tx_cnt
          end

        total_rate =
          if min_ts != max_ts do
            (total_txs_cnt * 1000) / abs(max_ts - min_ts)
          else
            total_txs_cnt
          end

        %{
          pre_ts: ts,
          total_txs_cnt: total_txs_cnt,
          min_ts: min_ts,
          max_ts: max_ts,
          last_rate: last_rate,
          total_rate: total_rate
        }
      end

    txs_stat = Enum.reduce(data, %{}, stat_fun)

    last_rate = Map.get(txs_stat, :last_rate, 0)
    total_rate = Map.get(txs_stat, :total_rate, 0)

    IO.puts("txs_stat: #{inspect txs_stat}")
    IO.puts(
      "\n**\n" <>
      "*  last_block_rate: #{last_rate}, total_rate: #{total_rate}\n" <>
      "**\n"
    )
  end

end
