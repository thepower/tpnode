defmodule TPHelpers.Resolver do

  @nodes_map %{
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

  def get_base_url(node \\ nil) do
    node_to_resolve =
      case node do
        nil ->
          get_default_node()
        _ ->
          node
      end

    url =
      case System.get_env("API_BASE_URL") do
        nil -> Map.get(@nodes_map, node_to_resolve)
        url_from_env -> url_from_env
      end

    unless url, do: raise "invalid node or invalid node url"

    to_charlist(url)
  end

  def get_default_node do
    Map.keys(@nodes_map)
    |> hd
  end

end
