defmodule TPHelpers do

  def is_node_alive?(node, opts \\ []) do
    host = Keyword.get(opts, :node, 'pwr')
    case :erl_epmd.port_please('test_#{node}', host) do
      {:port, _, _} -> true
      _ -> false
    end
  end

  def start_node(node, opts \\ []) do
    case is_node_alive?(node) do
      true -> logger("Skiping alive node ~p", [node])
      _ ->
        logger("Starting the node #{node}")

        dir = Keyword.get(opts, :dir, "./examples/test_chain4")
        bin_dirs_wildcard = Keyword.get(opts, :bin_dirs, "_build/test/lib/*/ebin/")

        bindirs = Path.wildcard(bin_dirs_wildcard)

        exec_args =
          ["-config", "#{dir}/test_#{node}.config", "-sname", "test_#{node}", "-noshell"] ++
          Enum.reduce(bindirs, [], fn x, acc -> ["-pa", x | acc] end) ++
          ["-detached", "+SDcpu", "2:2:", "-s", "lager", "-s", "tpnode"]

        System.put_env("TPNODE_RESTORE", dir)

        result = System.cmd("erl", exec_args)
        logger("result: ~p", [result])
    end

    :ok
  end


  def stop_node(node) do
    case is_node_alive?(node) do
      false -> logger("node #{node} is already down")
      _ ->
        logger("Stopping the node #{node}")
        result = :rpc.call(String.to_atom("test_#{node}@pwr"), :init, :stop, [])
        logger("result: ~p", [result])
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

  def logger(format, args \\ []), do: :utils.logger(to_charlist(format), args)

end
