defmodule TPHelpers do

  def is_node_alive?(node) do
    case :erl_epmd.port_please(:erlang.binary_to_list("test_#{node}"), 'pwr') do
      {:port, _, _} -> true
      _ -> false
    end
  end

end
