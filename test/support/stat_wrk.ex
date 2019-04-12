defmodule TPHelpers.StatWrk do
  @moduledoc """
    Implements websockets worker which receives statistics from a remote node
  """

  def start_link(opts \\ []) do
    IO.puts "WS worker start link"

    pid = spawn(__MODULE__, :run, [Keyword.put(opts, :parent, self())])
    :erlang.link(pid)
    {:ok, pid}
  end

  def run(opts) do
    IO.puts "WS worker run opts: #{inspect opts}"
    {:ok, _} = :application.ensure_all_started(:gun)
    :erlang.process_flag(:trap_exit, true)

    host = Keyword.get(opts, :host)
    port = Keyword.get(opts, :port)
    parent = Keyword.get(opts, :parent)

    try do
      IO.puts "WS worker connecting to #{inspect host}:#{port}"
      {:ok, pid} = :gun.open(host, port)

      receive do
        {:gun_up, ^pid, :http} ->
          :ok
      after 20_000 ->
        :gun.close(pid)
        throw(:up_timeout)
      end

      IO.puts "connected, upgrading to websockets"

      #      {200, _, _} = sync_get_decode(pid, "/api/ws")
      :gun.ws_upgrade(pid, "/api/ws")

      {:ok, ws_headers} =
        receive do
          {:gun_ws_upgrade, ^pid, status, headers} ->
            {status, headers}
        after 10_000 ->
          throw(:upgrade_timeout)
        end

      IO.puts "ws connection headers: #{inspect ws_headers}"

      IO.puts "make subscription"
      :ok = :gun.ws_send(pid, {:text, :jsx.encode(%{"sub" => "blockstat"})})

      send parent, {:wrk_up, self()}

      IO.puts "entering ws cycle"

      ws_mode(pid, parent)

      :gun.close(pid)
      :normal
    catch
      :throw, :up_timeout ->
        send parent, {:wrk_down, self(), :error}
        IO.puts "WS worker connection to #{inspect host}:#{port} was timed out"
        :error

      ec, ee ->
        :utils.print_error("ws worker run failed", ec, ee, :erlang.get_stacktrace())
        IO.puts "WS worker run failed, #{inspect ee}"
        send parent, {:wrk_down, self(), {:error, ee}}
        :error
    end
  end

  def ws_mode(pid, parent) do
    receive do
      {'EXIT', _, :shutdown} ->
        :gun.close(pid)
        exit(:normal)
      {'EXIT', _, reason} ->
        IO.puts("Linked process went down #{inspect reason}. Giving up...")
        :gun.close(pid)
        exit(:normal)
      {:state, caller} ->
        send caller, {pid, parent}
        ws_mode(pid, parent)
      :stop ->
        IO.puts("got stop command")
        :gun.close(pid)
        send parent, {:wrk_down, self(), :stop}
      {:send_msg, payload} ->
        :gun.ws_send(pid, {:binary, payload})
        ws_mode(pid, parent)
      {:gun_ws, ^pid, {:text, txt}} ->
        IO.puts("got text, #{inspect txt}")
#        :utils.logger("got text: ~p", [txt])
        ws_mode(pid, parent)
      {:gun_ws, ^pid, {:binary, bin}} ->
        IO.puts("got binary, #{inspect bin}")
#        :utils.logger("got binary: ~p", [bin])
        ws_mode(pid, parent)
      {:gun_down, ^pid, :ws, :closed, [], []} ->
        IO.puts "Gun down. Giving up..."
        send parent, {:wrk_down, self(), :gun_down}
        :giveup
      any ->
        IO.puts("WS worker got unknown data: #{inspect any}")
#        :utils.logger("WS worker got unknown data: ~p", [any])
        ws_mode(pid, parent)
    after 60_000 ->
      :ok = :gun.ws_send(pid, {:binary, "ping"})
      ws_mode(pid, parent)
    end
  end

  def sync_get_decode(pid, url) do
    {code, header, body} = sync_get(pid, url)
    case :proplists.get_value("content-type", header) do
      "application/json" ->
        {code, header, :jsx.decode(:erlang.iolist_to_binary(body), [:return_maps])}
      _ ->
        {code, header, body}
    end
  end

  def sync_get(pid, url) do
    ref = :gun.get(pid, url)
    sync_get_continue(pid, ref, {0, [], []})
  end

  def sync_get_continue(pid, ref, {pcode, phdr, pbody}) do
    {fin, ns} =
      receive do
        {:gun_response, ^pid, ^ref, is_fin, code, headers} ->
          {is_fin, {code, headers, pbody}}
        {:gun_data, ^pid, ^ref, is_fin, payload} ->
          {is_fin, {pcode, phdr, pbody ++ [payload]}}
      after 10_000 ->
        throw(:get_timeout)
      end

    case fin do
      :fin ->
        ns;
      :nofin ->
        sync_get_continue(pid, ref, ns)
    end
  end
end
