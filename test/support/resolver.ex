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

  @node_keys_map %{
    "c4n1" => "CF2BD71347FA5D645FD6586CD4FE426AF5DCC2A604C5CC2529AB6861DC948D54",
    "c4n2" => "15A48B170FBDAC808BA80D1692305A8EFC758CBC11252A4338131FC68AFAED6B",
    "c4n3" => "2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0"
  }

  def get_base_url(node \\ nil) do
    node_to_resolve = resolve_node(node)

    url =
      case System.get_env("API_BASE_URL") do
        nil -> Map.get(@nodes_map, node_to_resolve)
        url_from_env -> url_from_env
      end

    unless url, do: raise "invalid node or invalid node url"

    to_charlist(url)
  end

  def get_api_host_and_port(node \\ nil) do
    node_to_resolve = resolve_node(node)
    url = Map.get(@nodes_map, node_to_resolve, "")

    Regex.named_captures(~r/\/\/(?<host>[^:]+):(?<port>\d+)/, url)
  end

  def get_default_node do
    Map.keys(@nodes_map)
    |> hd
  end

  @spec get_priv_key(binary() | nil) :: binary
  def get_priv_key(node \\ nil) do
    node_to_resolve =
      unless node do
        get_default_node()
      else
        node
      end

    {:ok, binary_key} = Base.decode16(Map.get(@node_keys_map, node_to_resolve, ""))
    binary_key
  end

  defp resolve_node(node) do
    unless node do
      get_default_node()
    else
      node
    end
  end

  def get_all_priv_keys(node_regex \\ nil) do
    search_regex =
      unless node_regex do
        ~r/.+/
      else
        node_regex
      end

    Map.keys(@node_keys_map)
    |> Enum.filter(&Regex.match?(search_regex, &1))
    |> Enum.reduce(
         [],
         fn (node_name, acc) -> [:hex.decode(Map.get(@node_keys_map, node_name, [])) | acc] end
       )
    |> List.flatten
  end
end
