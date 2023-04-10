-module(contract_evm_abi).

-export([parse_abifile/1]).
-export([find_function/2, find_event/2]).
-export([all_events/1, mk_sig/1]).
-export([sig_events/1]).
-export([decode_abi/2]).
-export([decode_abi_map/2]).
-export([encode_simple/1]).
-export([encode_abi/2]).

-export([pack/1,unpack/1]).

-include_lib("eunit/include/eunit.hrl").

sig_events(ABI) ->
  [ begin
      S=mk_sig(E),
      {ok,H} = ksha3:hash(256,S),
      {S,H,In}
    end|| E={{event,_},In,_} <- ABI ].

all_events(ABI) ->
  lists:filter(
    fun({{event,_},_,_}) -> true; (_) -> false end,
    ABI).

decode_abi(Bin,Args) ->
  decode_abi(Bin,Args,Bin,[]).

decode_abi_map(Bin,Args) ->
  maps:from_list(decode_abi(Bin,Args,Bin,[])).

decode_abi(_,[],_Bin,Acc) ->
  {_,List}=lists:foldl(
    fun
      ({'_naked',_Type,Value},{N,A}) ->
        {N-1,[Value|A]};
      ({Name,_Type,Value},{N,A}) ->
        {N-1,[{
           if(Name == <<>>) ->
               <<"arg",(integer_to_binary(N))/binary>>;
             true ->
               Name
           end,
           Value
          } | A ]}
    end,
    {length(Acc),[]},
    Acc
   ),
  List;

decode_abi(<<Ptr:256/big,RestB/binary>>,[{Name, {array,Type}}|RestA],Bin,Acc) ->
  %io:format("~w ~p: ~w ~.16B~n",[?LINE,Name,Type,Ptr]),
  <<_:Ptr/binary,Size:256/big,Data/binary>> = Bin,
  %hexdump(Bin),
  %hexdump(<<Size:256/big,Data/binary>>),
  Tpl=decode_abi(Data,[{'_naked',Type} || _ <- lists:seq(1,Size)],Data,[]),
  decode_abi(RestB, RestA, Bin, [{Name, tuple, Tpl}|Acc]);

decode_abi(<<Ptr:256/big,RestB/binary>>,[{Name, {tuple,TL}}|RestA],Bin,Acc) ->
  %io:format("~w ~p: ~w ~.16B~n",[?LINE,Name,TL,Ptr]),
  <<_:Ptr/binary,Tuple/binary>> = Bin,
  %hexdump(<<Ptr:256/big,RestB/binary>>),
  %hexdump(Tuple),
  Tpl=decode_abi(Tuple,TL,Tuple,[]),
  decode_abi(RestB, RestA, Bin, [{Name, tuple, Tpl}|Acc]);

decode_abi(<<Ptr:256/big,RestB/binary>>,[{Name,bytes}|RestA],Bin,Acc) ->
  <<_:Ptr/binary,Len:256/big,Str:Len/binary,_/binary>> = Bin,
  decode_abi(RestB, RestA, Bin, [{Name, string, Str}|Acc]);

decode_abi(<<Ptr:256/big,RestB/binary>>,[{Name,string}|RestA],Bin,Acc) ->
  %io:format("~w ~p: ~w ~.16B~n",[?LINE,Name,string,Ptr]),
  <<_:Ptr/binary,Len:256/big,Str:Len/binary,_/binary>> = Bin,
  decode_abi(RestB, RestA, Bin, [{Name, string, Str}|Acc]);

decode_abi(<<Val:256/big,RestB/binary>>,[{Name,address}|RestA],Bin,Acc)
  when Val > 9223372036854775808 andalso Val < 13835058055282163712 ->
  %io:format("~w ~p ~p~n",[?LINE,Name,Val]),
  decode_abi(RestB, RestA, Bin, [{Name, address, binary:encode_unsigned(Val)}|Acc]);
decode_abi(<<Val:256/big,RestB/binary>>,[{Name,address}|RestA],Bin,Acc) ->
  %io:format("~w~n",[?LINE]),
  decode_abi(RestB, RestA, Bin, [{Name, address, Val}|Acc]);
decode_abi(<<Val:256/big,RestB/binary>>,[{Name,bool}|RestA],Bin,Acc) ->
  %io:format("~w~n",[?LINE]),
  decode_abi(RestB, RestA, Bin, [{Name, bool, Val==1}|Acc]);
decode_abi(<<_:248,Val:8/big,RestB/binary>>,[{Name,uint8}|RestA],Bin,Acc) ->
  %io:format("~w~n",[?LINE]),
  decode_abi(RestB, RestA, Bin, [{Name, uint8, Val}|Acc]);
decode_abi(<<Val:256/big,RestB/binary>>,[{Name,uint256}|RestA],Bin,Acc) ->
  %io:format("~w ~p ~p~n",[?LINE, Name, Val]),
  decode_abi(RestB, RestA, Bin, [{Name, uint256, Val}|Acc]).

find_function(ABI, Sig) when is_list(ABI), is_list(Sig) ->
  logger:notice("deprecated clause of find_function called"),
  find_function(list_to_binary(Sig), ABI);

find_function(Sig, ABI) when is_binary(Sig), is_list(ABI) ->
  {Name,Args} = sig_split(Sig),
  lists:filter(
    fun({{function,LName},_CS,_}) when LName == Name andalso Args==undefined ->
        true;
       ({{function,LName},CS,_}) when LName == Name ->
        [ Type || {_,Type} <- CS ] == Args;
       (_) ->
        false
    end,
    ABI).

find_event(Sig, ABI) when is_binary(Sig), is_list(ABI) ->
  {Name,Args} = sig_split(Sig),
  lists:filter(
    fun
      ({{event,LName},_,_}) when LName == Name andalso Args==undefined ->
        true;
      ({{event,LName},CS,_}) when LName == Name ->
        [ Type || {_,Type} <- CS ] == Args;
       (_) ->
        false
    end,
    ABI).

mk_sig([]) ->
  []; % convert multiple
mk_sig([{{event,_},_,_}=E|Rest]) ->
  [ mk_sig(E) | mk_sig(Rest) ];
mk_sig([{{function,_},_,_}=E|Rest]) ->
  [ mk_sig(E) | mk_sig(Rest) ];
mk_sig([_|Rest]) ->
  mk_sig(Rest);

mk_sig({{EventOrFunction,Name},CS,_}) when EventOrFunction == event;
                                           EventOrFunction == function ->
  list_to_binary([
                  Name,
                  "(",
                  lists:join(",", [ mk_sig_type(E) || E <- CS ]),
                  ")"
                 ]).

mk_sig_type({_,{tuple,_Type}}) ->
  <<"tuple">>;

mk_sig_type({_,Type}) when is_atom(Type) ->
  atom_to_binary(Type,utf8).

sig_split(Signature) ->
  case re:run(Signature,
              "^([01-9a-zA-Z_]+)\\\((.*)\\\)",
              [{capture, all_but_first, binary}]) of
    nomatch ->
      case re:run(Signature,
                  "^([01-9a-zA-Z_]+)$",
                  [{capture, all_but_first, binary}]) of
        nomatch ->
          {error, {invalid_signature, Signature}};
        {match, [Name]} ->
          {Name, undefined}
      end;
    {match,[Fun,Args]} ->
      {Fun,
       [ convert_type(T) || T<- binary:split(Args,<<",">>,[global]), size(T)>0]
      }
  end.

parse_abilist([_|_]=JSON) ->
  lists:filtermap(
    fun parse_item/1,
    JSON
   ).

load_abifile(Filename) ->
  {ok, Bin} = file:read_file(Filename),
  jsx:decode(Bin,[return_maps]).

parse_abifile(Filename) ->
  JSON=load_abifile(Filename),
  parse_abilist(JSON).

parse_item(#{
             <<"outputs">> := O,
             <<"name">> := Name,
             <<"inputs">> := I,
             <<"type">> := <<"function">>
  %{<<"stateMutabil"...>>,<<"view">>},
  %{<<"type">>,<<"func"...>>}
            }) ->
  {true,{{function,Name},convert_io(I),convert_io(O)}};
parse_item(#{
             <<"name">> := Name,
             <<"inputs">> := I,
             <<"type">> := <<"event">>
            }) ->
  {true,{{event,Name},convert_io(I),[]}};
parse_item(#{
             <<"inputs">> := I,
             <<"type">> := <<"constructor">>
            }) ->
  {true,{{constructor,default},convert_io(I),[]}};
parse_item(#{}=_Any) ->
  %io:format("Unknown item: ~p~n",[_Any]),
  false.

convert_io(List) ->
  lists:map(
    fun(#{
          <<"name">> := Name,
          <<"type">> := <<"tuple">>,
          <<"components">>:= C}) ->
        {Name, {tuple, convert_io(C)}};
       (#{
          <<"name">> := Name,
          <<"type">> := <<"tuple[]">>,
          <<"components">>:= C}) ->
        {Name, {array,{tuple, convert_io(C)}}};
        (#{
          <<"name">> := Name,
          <<"type">> := Type}) ->
        {Name, convert_type(Type)}
    end, List).


convert_type(<<"string">>) -> string;
convert_type(<<"address">>) -> address;
convert_type(<<"uint8">>) -> uint8;
convert_type(<<"bytes">>) -> bytes;
convert_type(<<"uint256">>) -> uint256;
convert_type(<<"string[]">>) -> {array,string};
convert_type(<<"uint256[]">>) -> {array,uint256};
convert_type(<<"uint8[]">>) -> {array,uint8};

convert_type(<<"bool">>) -> bool.

encode_type(<<Input:256/big>>, uint256) ->
  <<Input:256/big>>;
encode_type(Input, uint256) when is_integer(Input) ->
  <<Input:256/big>>;

encode_type(<<Input:256/big>>, uint8) ->
  <<(Input band 255):256/big>>;
encode_type(Input, uint8) when is_integer(Input) ->
  <<(Input band 255):256/big>>;

encode_type(Input, bool) when is_integer(Input) ->
  Val=if Input==0 -> 0; true -> 1 end,
  <<Val:256/big>>;
encode_type(Input, bool) when is_atom(Input) ->
  Val=if Input==false -> 0; true -> 1 end,
  <<Val:256/big>>;

encode_type(Input, address) when is_integer(Input) ->
  <<Input:256/big>>;
encode_type(Input, address) ->
  IVal=binary:decode_unsigned(Input),
  <<IVal:256/big>>;

encode_type(_, Type) ->
  throw({'unexpected_type',Type}).

encode_abi(D,ABI) ->
  HdLen=length(ABI)*32,
  encode_typed(D,ABI,<<>>,<<>>,HdLen).

encode_typed([],[], Hdr, Body, _BOff) ->
  <<Hdr/binary,Body/binary>>;

encode_typed([Val|RVal],[{_Name,{tuple,List}}|RType], Hdr, Body, BOff) ->
  HdLen=length(List)*32,
  EncStr=encode_typed(Val, List, <<>>, <<>>, HdLen),
  %io:format("< ENC tuple >> BOff ~.16B array ~p ~p~n",[BOff,Val,List]),
  %hexdump(<<BOff:256/big>>),
  %hexdump(EncStr),

  encode_typed(RVal, % CHECK IT
               RType,
               <<Hdr/binary,BOff:256/big>>,
               <<Body/binary,EncStr/binary>>,
               BOff+size(EncStr));

encode_typed([Val|RVal],[{_Name,{array,Type}}|RType], Hdr, Body, BOff) ->
  Len=length(Val),
  EncStr=encode_typed(Val,[{'_naked',Type} || _ <- lists:seq(1,Len)], <<Len:256/big>>, <<>>,
                      (Len*32)),
  %io:format("< ENC arr >> BOff ~.16B array ~p ~p~n",[BOff,Val,Type]),
  %hexdump(<<BOff:256/big>>),
  %hexdump(EncStr),

  encode_typed(RVal,
               RType,
               <<Hdr/binary,BOff:256/big>>,
               <<Body/binary,EncStr/binary>>,
               BOff+size(EncStr));

encode_typed([Val|RVal],[{_Name,string}|RType], Hdr, Body, BOff) ->
  EncStr=encode_str(Val),
  encode_typed(RVal,
               RType,
               <<Hdr/binary,BOff:256/big>>,
               <<Body/binary,EncStr/binary>>,
               BOff+size(EncStr));

encode_typed([Val|RVal],[{_Name,bytes}|RType], Hdr, Body, BOff) ->
  EncStr=encode_str(Val),
  encode_typed(RVal,
               RType,
               <<Hdr/binary,BOff:256/big>>,
               <<Body/binary,EncStr/binary>>,
               BOff+size(EncStr));

encode_typed([Val|RVal],[{_Name,Type}|RType], Hdr, Body, BOff) ->
  case encode_type(Val, Type) of
    Bin when is_binary(Bin) ->
      encode_typed(RVal,
                   RType,
                   <<Hdr/binary,Bin/binary>>,
                   Body,
                   BOff);
    {body,Bin} when is_binary(Bin) ->
      encode_typed(RVal,
               RType,
               <<Hdr/binary,BOff:256/big>>,
               <<Body/binary,Bin/binary>>,
               BOff+size(Bin))
  end.

encode_simple(Elements) ->
  HdLen=length(Elements)*32,
  {H,B,_}=lists:foldl(
            fun(E, {Hdr,Body,BOff}) when is_integer(E) ->
                {<<Hdr/binary,E:256/big>>,
                 Body,
                 BOff};
               ({bin, <<E:256/big>>}, {Hdr,Body,BOff}) ->
                {<<Hdr/binary,E:256/big>>,
                 Body,
                 BOff};
               (E, {Hdr,Body,BOff}) when is_binary(E) ->
                EncStr=encode_str(E),
                {
                 <<Hdr/binary,BOff:256/big>>,
                 <<Body/binary,EncStr/binary>>,
                 BOff+size(EncStr)
                }
            end, {<<>>, <<>>, HdLen}, Elements),
  HdLen=size(H),
  <<H/binary,B/binary>>.

encode_str(List) when is_list(List) ->
  encode_str(list_to_binary(List));

encode_str(Bin) ->
  Pad = case (size(Bin) rem 32) of
          0 -> 0;
          N -> 32 - N
        end*8,
  <<(size(Bin)):256/big,Bin/binary,0:Pad/big>>.

pack(JSON) ->
  Dict=lists:reverse(lists:keysort(2,maps:to_list(mkdict(JSON, #{})))),
  {_,PL}=lists:foldl(
            fun
              ({_,1}, {Acc,Lst}) -> {Acc,Lst};
              ({S,_}, {Acc,Lst}) when size(S) < 4 -> {Acc,Lst};
              ({Name,_Cnt}, {Acc,Lst}) ->
                {Acc+1,[{Name,Acc}|Lst]}
            end,{1,[]},Dict),
  Mapa=maps:from_list(PL),
  LL=lists:foldl( fun({L,_Idx}, Acc) -> [L|Acc] end, [], PL),
  Enc=transform_list(JSON, Mapa),
  zlib:compress(msgpack:pack([<<"abiv1">>, LL, Enc ])).

unpack(Bin) ->
  {ok,[<<"abiv1">>, LL, Enc]}=msgpack:unpack(zlib:uncompress(Bin)),
  Mapa=maps:from_list(lists:zip(lists:seq(1, length(LL)), LL)),
  retransform_list(Enc, Mapa).

transform_map(Data, Map) ->
  T=fun(B) -> maps:get(B, Map, B) end,
  maps:fold(
    fun(K,V,Acc1) when is_binary(K) andalso is_list(V) ->
        maps:put(T(K),transform_list(V, Map),Acc1);
       (K,V,Acc1) when is_binary(K) andalso is_map(V) ->
        maps:put(T(K),transform_map(V, Map),Acc1);
       (K,V,Acc1) when is_binary(K) andalso is_binary(V) ->
        maps:put(T(K),T(V),Acc1);
       (K,V,Acc1) when is_binary(K) andalso is_atom(V) ->
        maps:put(T(K),V,Acc1);
       (Key,_Val,_) ->
        throw({'unexpected_key',{Key,_Val}})
    end, #{}, Data).

transform_list(Data, Map) ->
  T=fun(B) -> maps:get(B, Map, B) end,
  lists:map(
    fun({K,V}) when is_binary(K) andalso is_list(V) ->
        {T(K),transform_list(V, Map)};
       ({K,V}) when is_binary(K) andalso is_map(V) ->
        {K,transform_map(V, Map)};
       ({K,V}) when is_binary(K) andalso is_binary(V) ->
        {K,V};
       (V) when is_map(V) ->
        transform_map(V, Map);
       (K) when is_binary(K) ->
        T(K);
       (Key) ->
        throw({'unexpected_key',Key})
    end, Data).

retransform_map(Data, Map) ->
  T=fun(B) -> maps:get(B, Map, B) end,
  maps:fold(
    fun(K,V,Acc1) when (is_integer(K) orelse is_binary(K)) andalso is_list(V) ->
        maps:put(T(K),retransform_list(V, Map),Acc1);
       (K,V,Acc1) when (is_integer(K) orelse is_binary(K)) andalso is_map(V) ->
        maps:put(T(K),retransform_map(V, Map),Acc1);
       (K,V,Acc1) when (is_integer(K) orelse is_binary(K)) andalso
                       (is_integer(V) orelse is_binary(V)) ->
        maps:put(T(K),T(V),Acc1);
       (K,V,Acc1) when (is_binary(K) orelse is_integer(K)) andalso is_atom(V) ->
        maps:put(T(K),V,Acc1);
       (Key,_Val,_) ->
        throw({'unexpected_key',{Key,_Val}})
    end, #{}, Data).

retransform_list(Data, Map) ->
  T=fun(B) -> maps:get(B, Map, B) end,
  lists:map(
    fun({K,V}) when is_binary(K) andalso is_list(V) ->
        {T(K),retransform_list(V, Map)};
       ({K,V}) when is_binary(K) andalso is_map(V) ->
        {K,retransform_map(V, Map)};
       ({K,V}) when is_binary(K) andalso is_binary(V) ->
        {K,V};
       (V) when is_map(V) ->
        retransform_map(V, Map);
       (K) when is_binary(K) ->
        T(K);
       (Key) ->
        throw({'unexpected_key',Key})
    end, Data).



mkdict(Map, Acc) ->
  lists:foldl(
    fun(V,Acc1) when is_map(V) ->
        mkdict(maps:to_list(V), Acc1);
       ({K,V},Acc1) when is_binary(K) andalso is_list(V) ->
        mkdict(V, maps:put(K, maps:get(K, Acc1, 0)+1, Acc1));
       ({K,V},Acc1) when is_binary(K) andalso is_map(V) ->
        mkdict(V, maps:put(K, maps:get(K, Acc1, 0)+1, Acc1));
       ({K,V},Acc1) when is_binary(K) andalso is_binary(V) ->
        Acc2=maps:put(K, maps:get(K, Acc1, 0)+1, Acc1),
        maps:put(V, maps:get(V, Acc2, 0)+1, Acc2);
       ({K,V},Acc1) when is_binary(K) andalso is_atom(V) ->
        maps:put(K, maps:get(K, Acc1, 0)+1, Acc1);
       (Key,_Val) ->
        throw({'unexpected_key',Key})
    end, Acc, Map).

tuple_array_test() ->
  ABI=[{<<>>,{array,{tuple,[{<<"id">>,uint256},{<<"text">>,string}]}}}],
  Bin=hex:decode(
        "0000000000000000000000000000000000000000000000000000000000000020"
        "0000000000000000000000000000000000000000000000000000000000000002"
        "0000000000000000000000000000000000000000000000000000000000000040"
        "00000000000000000000000000000000000000000000000000000000000000C0"
        "000000000000000000000000000000000000000000000000000000000000007B"
        "0000000000000000000000000000000000000000000000000000000000000040"
        "0000000000000000000000000000000000000000000000000000000000000003"
        "3332310000000000000000000000000000000000000000000000000000000000"
        "000000000000000000000000000000000000000000000000000000000000029A"
        "0000000000000000000000000000000000000000000000000000000000000040"
        "0000000000000000000000000000000000000000000000000000000000000003"
        "3636360000000000000000000000000000000000000000000000000000000000"),
  Bin2=encode_abi([[[123,"321"],[666,"666"]]],ABI),
  [
   ?assertMatch([{_, [[{<<"id">>,123},{<<"text">>,<<"321">>}],
                      [{<<"id">>,666},{<<"text">>,<<"666">>}]]}],
                decode_abi(Bin,ABI)
               ),
   ?assertEqual(Bin, Bin2)
  ].


