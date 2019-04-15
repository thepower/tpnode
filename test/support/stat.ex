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
        mode: :idle
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

  def handle_cast({:got, data}, state) do
    parse_ws_data(data)
    {:noreply, state}
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
      IO.puts "got ws: #{inspect json}"
      %{"blockstat" => %{"txs_cnt" => txs_cnt}} = json
      IO.puts "txs count: #{inspect txs_cnt}"
      {:ok, txs_cnt}
    catch
      ec, ee ->
        :utils.print_error("parse wd data failed", ec, ee, :erlang.get_stacktrace())
        :error
    end
  end

end
