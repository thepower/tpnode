-module(ygg).
-export([addr_for_key/1, test/0]).
-export([example/0, config_file/1, nodepriv/1, executable/0]).
-export([start_stack/1]).

-include_lib("eunit/include/eunit.hrl").

start_stack(Config) ->
  yggstack:start_link(Config).

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
              <<"tls://ygg.cleverfox.org:15015?key=000000009982cb0feb442dd436c25868f8778f8f9199ae19dd10087ab2589847">>
             ]
   }.


config_file(#{priv:=Priv, listen:=Listen, admin:=Admin, peers:=Peers}) ->
  jsx:encode(#{ <<"PrivateKey">> => binary:encode_hex(nodepriv(Priv)),
                <<"Peers">> => Peers,
                <<"Listen">> => [
                                 <<"[::]:",(integer_to_binary(Listen))/binary>>,
                                 <<"0.0.0.0:",(integer_to_binary(Listen))/binary>>
                                ],
                <<"AdminListen">> => <<"127.0.0.1:",(integer_to_binary(Admin))/binary>>,
                <<"MulticastInterfaces">> => [],
                <<"IfName">> => <<"none">>,
                <<"NodeInfoPrivacy">> => false,
                <<"NodeInfo">> => #{}
              }).
     
executable() ->
  Name="yggstack",
  case os:find_executable(Name) of
    false ->
      Executable=filename:join(code:priv_dir(yggerl),Name),
      case filelib:is_regular(Executable) of
        true ->
          Executable;
        false -> false
      end;
    L ->
      L
  end.

run(Config,Services) ->
  Executable=case executable() of
               false -> throw(no_yggstack_found);
               L -> L
             end,
  ok=file:write_file("_tmp_cfg",Config),
  H=erlang:open_port(
    {spawn_executable, Executable},
    [{args, ["-useconffile", "_tmp_cfg" ]},
     eof,
     binary,
     stderr_to_stdout
    ]),
  timer:sleep(200),
  ok=file:delete("_tmp_cfg"),
  %H ! {self(), {command, Config}},
  %H ! {self(), eof},
  %erlang:port_close(H).
  H.


%cat y1 | ./yggstack_freebsd -useconf -socks 0.0.0.0:19919

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

