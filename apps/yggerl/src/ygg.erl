-module(ygg).
-export([addr_for_key/1, test/0]).
-export([example/0, config_file/1, nodepriv/1, executable/0, arch/0]).
-export([start_stack/1, generate_priv/1]).

-include_lib("eunit/include/eunit.hrl").

start_stack(Config) ->
  yggstack:start_link(Config).

arch() ->
  {_Unix,Os}=os:type(),
  [
   atom_to_list(Os),
   lists:nth(1, string:tokens(erlang:system_info(system_architecture), "-"))
  ].

nodepriv(<<Priv:32/binary>>) ->
  {<<XPub:32/binary>>, <<XPriv:32/binary>>} = crypto:generate_key(eddsa, ed25519, Priv),
  <<XPriv/binary,XPub/binary>>;

nodepriv(Key) ->
  {priv,ed25519,Priv}=tpecdsa:rawkey(Key),
  nodepriv(Priv).

example() ->
  ListenPort=utils:alloc_tcp_port(),
  AdminPort=utils:alloc_tcp_port(),
  #{
    priv => nodekey:get_priv(),
    listen => ListenPort,
    admin => AdminPort,
    peers => [
              <<"tls://mima.localghost.org:443">>,
              <<"tls://ygg.cleverfox.org:15015">>
             ]
   }.


config_file(#{priv:=Priv, listen:=Listen, admin:=Admin, peers:=Peers}) ->
  jsx:encode(#{ <<"PrivateKey">> => binary:encode_hex(nodepriv(Priv)),
                <<"Peers">> => Peers,
                <<"Listen">> => [
                                 %<<"[::]:",(integer_to_binary(Listen))/binary>>,
                                 <<"tls://0.0.0.0:",(integer_to_binary(Listen))/binary>>
                                ],
                <<"AdminListen">> => if is_integer(Admin) ->
                                          <<"127.0.0.1:",(integer_to_binary(Admin))/binary>>;
                                        is_list(Admin) ->
                                          <<"unix://",(list_to_binary(Admin))/binary>>
                                     end,
                <<"MulticastInterfaces">> => [],
                <<"IfName">> => <<"none">>,
                <<"NodeInfoPrivacy">> => false,
                <<"NodeInfo">> => #{}
              }).
     
executable() ->
  Name="yggstack",
  case os:find_executable(Name) of
    false ->
      Name1=lists:join("-",[Name|ygg:arch()]),
      Executable=filename:join(code:priv_dir(yggerl),Name1),
      case filelib:is_regular(Executable) of
        true ->
          Executable;
        false ->
          logger:info("yggstack not found ~s in $PATH nor at ~s",[Name,Executable]),
          false
      end;
    L ->
      L
  end.

% This module converts public key to yggdrasil address

get_prefix() ->
  <<2>>.

shbin(Bits, Bin) ->
  S=size(Bin),
  <<_:Bits, Sh:(S-1)/binary,_:(8-Bits)>> = Bin,
  Sh.

calc_ones(<<N:8, Rest/binary>> = All) ->
  LO=calc_ones(N),
  if(LO==8) ->
      {O,R}=calc_ones(Rest),
      {O+LO,R};
    true ->
      {LO,shbin(LO+1,All)}
  end;

calc_ones(0) -> 0;
calc_ones(N) when N==255 -> 8;
calc_ones(N) when N==254 -> 7;
calc_ones(N) when N>=252 -> 6;
calc_ones(N) when N>=248 -> 5;
calc_ones(N) when N>=240 -> 4;
calc_ones(N) when N>=224 -> 3;
calc_ones(N) when N>=192 -> 2;
calc_ones(N) when N>=128 -> 1;
calc_ones(N) when N<128  -> 0.

addr_for_key(<<Pubkey:32/binary>>) ->
  Prefix = get_prefix(),
  Inverse = << <<(B bxor 255):8>> || <<B:8/integer>> <= Pubkey>>,
  {Ones,R}=calc_ones(Inverse),
  <<X:16/binary,_/binary>> = <<Prefix/binary, 0:1, Ones:7, R/binary>>,
  list_to_tuple([ P || <<P:16/integer>> <= X]).

generate_priv(Diff) ->
  generate_priv(Diff,{<<>>,0}).

generate_priv(Diff,{_,PD}=Best) ->
  {Pub,Priv} = crypto:generate_key(eddsa,ed25519),
  HD=hashdiff(Pub),
  if HD>14 orelse HD>=Diff ->
       io:format("Pub ~s diff ~w pvt ~s best ~w~n",[
                                            hex:encodex(Pub),
                                            HD,
                                            hex:encodex(Priv),
                                            PD
                                           ]);
     true -> ok 
  end,

  if HD<Diff ->
       generate_priv(Diff,
                      case HD>PD of
                        true ->
                          {Priv,HD};
                        false ->
                          Best
                      end);
     true ->
       hex:hexdump(Priv),
       hex:hexdump(Pub),
       io:format("IP address ~s~n",[inet:ntoa(addr_for_key(Pub))]),
       Priv
  end.

test() ->
  [
   ?assertEqual(
      inet:ntoa(addr_for_key(hex:decode("cc4f5d82224b258f50c4ce451c9848abcc0f60dc3f8d215025dbd8fa00a51f0e"))),
      "200:6761:44fb:bb69:b4e1:5e76:6375:c6cf"
     ),
   ?assertEqual(
      inet:ntoa(addr_for_key(hex:decode("000000513000e5369e78722ab2474a7f3d71ee2cae783cbf638058e020dc933c"))),
      "219:bb3f:fc6b:2586:1e37:5536:e2d6:30a"
     )
  ].

intdiff(I) when I>0 andalso I<128 ->
  intdiff(I bsl 1)+1;

intdiff(_I) ->
  0.

hashdiff(<<0,_Rest/binary>>) ->
  hashdiff(_Rest)+8;

hashdiff(<<I:8/integer,_Rest/binary>>) ->
  intdiff(I);

hashdiff(_) ->
  0.

