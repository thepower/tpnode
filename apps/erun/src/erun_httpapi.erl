-module(erun_httpapi).

-export([h/3, after_filter/1 ]).

-export([answer/0, answer/1, answer/2, err/1, err/2, err/3, err/4]).


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.



add_address(Address, Map1) ->
    HexAddress = <<"0x",(hex:encode(Address))/binary>>,
    TxtAddress = naddress:encode(Address),

    maps:merge(Map1, #{
        <<"address">> => HexAddress,
        <<"txtaddress">> => TxtAddress
    }).


err(ErrorCode) ->
    err(ErrorCode, <<"">>, #{}, #{}).

err(ErrorCode, ErrorMessage) ->
    err(ErrorCode, ErrorMessage, #{}, #{}).

err(ErrorCode, ErrorMessage, Data) ->
    err(ErrorCode, ErrorMessage, Data, #{}).

err(ErrorCode, ErrorMessage, Data, Options) ->
    Required0 =
        #{
            <<"ok">> => false,
            <<"code">> => ErrorCode,
            <<"msg">> => ErrorMessage
        },

    % add address if it exists
    Required1 = case maps:is_key(address, Options) of
        true ->
            add_address(
                maps:get(address, Options),
                Required0
            );
        _ ->
            Required0
    end,
    {
        maps:get(http_code, Options, 200),
        maps:merge(Data, Required1)
    }.

answer() ->
    answer(#{}).

answer(Data) ->
    answer(Data, #{}).

answer(Data, Options) when is_map(Data) ->
  Data1 =
  case maps:is_key(address, Options) of
    true ->
      add_address(
        maps:get(address, Options),
        Data
       );
    _ ->
      Data
  end,
  Data2=maps:put(<<"ok">>, true, Data1),
  MS=maps:with([jsx,msgpack],Options),
  case(maps:size(MS)>0) of
    true ->
      {
       200,
       {Data2,MS}
      };
    false ->
      {
       200,
       Data2
      }
  end.



after_filter(Req) ->
  Origin=cowboy_req:header(<<"origin">>, Req, <<"*">>),
  Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                  Origin, Req),
  Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                  <<"GET, POST, OPTIONS">>, Req1),
%  Req3=cowboy_req:set_resp_header(<<"access-control-allow-credentials">>,
%                                  <<"true">>, Req2),
  Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                  <<"86400">>, Req2),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                             <<"content-type">>, Req4).

h(<<"GET">>, [<<"run">>|_], _Req) ->
  err(
    10000,
    <<"GET method does not supported">>,
    #{result => <<"error">>},
    #{http_code => 400}
   );

h(<<"POST">>, [<<"run">>,TAddr], Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> ->
             hex:parse(Hex);
           _ ->
             naddress:decode(TAddr)
         end,

    #{<<"method">>:=Method,
      <<"arguments">>:=Args
     }=JSON=apixiom:bodyjs(Req),
    Gas=10000,
    Args1=lists:map(
            fun(<<"0x",Hex/binary>>) ->
                binary:decode_unsigned(hex:decode(Hex));
               (Int) when is_integer(Int) ->
                Int;
               (Bin) when is_binary(Bin) ->
                binary:decode_unsigned(Bin)
            end, Args),
    Node=binary_to_list(maps:get(<<"node">>,JSON,<<"http://195.3.252.69:49841">>)),
    {FinR,Data,Stack}=erun_querier:q(Node,Addr,Method,Args1, Gas),
    answer(
      #{
         address => <<"0x",(hex:encode(Addr))/binary>>,
         method => Method,
         args => Args1,
         gas_limit => Gas,
         result => FinR,
         data => if Data == <<>> ->
                      <<>>;
                    is_binary(Data) ->
                      <<"0x",(hex:encode(Data))/binary>>;
                    Data==undefined ->
                      null;
                    is_atom(Data) ->
                      Data
                 end,
         stack => Stack
       }
     )
  catch error:{badmatch,_}=BadMatch:S ->
          logger:error("Error badmatch ~p @ ~p",[BadMatch,hd(S)]),
          err(
            10001,
            <<"Invalid arguments">>,
            #{result => <<"error">>},
            #{http_code => 400}
           );
        throw:{error, address_crc} ->
          err(
            10010,
            <<"Invalid address">>,
            #{
              result => <<"error">>,
              error => <<"invalid address">>
             }
           )

  end;
%  case txpool:new_tx(BinTx) of
%    {ok, Tx} ->
%      answer(
%       #{ result => <<"ok">>,
%          txid => Tx
%        }
%      );
%    {error, Err} ->
%      lager:info("error ~p", [Err]),
%      err(
%          10008,
%          iolist_to_binary(io_lib:format("bad_tx:~p", [Err])),
%          #{},
%          #{http_code=>500}
%      )
%  end;

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};

h(_Method, [<<"status">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  lager:info("Join from ~p", [inet:ntoa(RemoteIP)]),
  answer( #{ client => list_to_binary(inet:ntoa(RemoteIP)) }).

