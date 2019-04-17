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
    "c4n3" => "2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0",
    "c5n1" => "A164B0F8E84FC13BC95B2B2747DE8D4A780C21F6E33B3435BC2277C456AA007C",
    "c5n2" => "B3C8CF0317D9228018C647F54E388A133708875C00E787266F682FBC25C8A01A",
    "c5n3" => "158729788B952BDE8073DEA6EAEE3A833F98A8EB8CBD23A83CC771656D7CE25B",
    "c6n1" => "7DABC8CAE611B9E36080189FB9A1F9CA1F6AC1A7AB0ED4CFBE6BB3A7342FBC30",
    "c6n2" => "C6B6CD3076AB2A719260833304C76EB7586E0D083BCDC42D968CCA1953BA0D7C",
    "c6n3" => "18F0BE8ECFA6E4993EA2273AA9569B02C8ACA7A75862A2A72C8B8F1058E1E92E"
  }

  def get_base_url(node \\ nil) do
    node_to_resolve = node || get_default_node()
    url = System.get_env("API_BASE_URL") || Map.get(@nodes_map, node_to_resolve)

    unless url, do: raise "invalid node or invalid node url"

    to_charlist(url)
  end

  def get_api_host_and_port(node \\ nil) do
    node_to_resolve = node || get_default_node()
    url = Map.get(@nodes_map, node_to_resolve, "")

    Regex.named_captures(~r/\/\/(?<host>[^:]+):(?<port>\d+)/, url)
  end

  def get_default_node do
    Map.keys(@nodes_map)
    |> hd
  end

  @spec get_priv_key(binary() | nil) :: binary
  def get_priv_key(node \\ nil) do
    node_to_resolve = node || get_default_node()

    {:ok, binary_key} = Base.decode16(Map.get(@node_keys_map, node_to_resolve, ""))
    binary_key
  end


  def get_all_priv_keys(node_regex \\ nil) do
    search_regex = node_regex || ~r/.+/

    Map.keys(@node_keys_map)
    |> Enum.filter(&Regex.match?(search_regex, &1))
    |> Enum.reduce(
         [],
         fn (node_name, acc) -> [:hex.decode(Map.get(@node_keys_map, node_name, [])) | acc] end
       )
    |> List.flatten
  end
end
