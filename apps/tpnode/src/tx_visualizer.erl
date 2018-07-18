-module(tx_visualizer).

-export([show/1]).

-define (D(Type, Val, TL, LL), self() ! {d, Depth, Type, Val, TL, LL}).

format(Type, TL, LL, Bin) when Type==arr orelse Type==map ->
  <<_Tag:TL,Len:LL>>=Bin,
%  TagFormat="0b~"++integer_to_list(TL)++".2.0B",
%  LenFormat="0b~"++integer_to_list(LL)++".2.0B",
  #{type=>Type,
%    btag=>iolist_to_binary(io_lib:format(TagFormat,[Tag])),
%    blen=>iolist_to_binary(io_lib:format(LenFormat,[Len])),
    len=>Len
   };
%  io_lib:format(" ~s size ~b "++TagFormat++" "++LenFormat,
%                [ Type, Len, Tag, Len]);

format(str=Type, TL, LL, Bin) ->
  <<_Tag:TL,Len:LL,Str/binary>>=Bin,
%  TagFormat="0b~"++integer_to_list(TL)++".2.0B",
%  LenFormat="0b~"++integer_to_list(LL)++".2.0B",
  #{type=>Type,
%    btag=>iolist_to_binary(io_lib:format(TagFormat,[Tag])),
%    blen=>iolist_to_binary(io_lib:format(LenFormat,[Len])),
    len=>Len,
    str=>Str
   };
  %io_lib:format("~s "++TagFormat++" "++LenFormat++" \"~s\"",
  %              [ Type, Tag, Len, Str]);

format(bin=Type, TL, LL, Bin) ->
  <<_Tag:TL,Len:LL,Str/binary>>=Bin,
%  TagFormat="0b~"++integer_to_list(TL)++".2.0B",
%  LenFormat="0b~"++integer_to_list(LL)++".2.0B",
  #{type=>Type,
%    btag=>iolist_to_binary(io_lib:format(TagFormat,[Tag])),
%    blen=>iolist_to_binary(io_lib:format(LenFormat,[Len])),
    len=>Len,
    str=>hex:encode(Str)
   };
%  io_lib:format("~s "++TagFormat++" "++LenFormat++" \"~s\"",
%                [ Type, Tag, Len, hex:encode(Str)]);

format(uint=Type, 8, 0, Bin) ->
  S=bit_size(Bin)-8,
  <<_Tag:8/integer,Val:S/big>>=Bin,
  #{type=>Type,
%    btag=>iolist_to_binary(io_lib:format("0b~8.2.0B",[Tag])),
    len=>size(Bin)-1,
    int=>Val
   };
%  io_lib:format("~s 0b~8.2.0B = ~B",[ Type, Tag, Val]);

format(int5=Type, 3, 0, Bin) ->
  <<_Tag:3/integer,Val:5/big>>=Bin,
  #{type=>Type,
    len=>1,
    int=>Val
   };
%
format(uint=Type, 1, 0, Bin) ->
  S=bit_size(Bin)-1,
  <<_Tag:1/integer,Val:S/big>>=Bin,
  #{type=>Type,
%    btag=>iolist_to_binary(io_lib:format("0b~1.2.0B",[Tag])),
    len=>1,
    int=>Val
   };
%  io_lib:format("~s 0b~1.2.0B = ~B",[ Type, Tag, Val]);

format(Type, TL, 0, Bin) when TL==8 orelse TL==16 orelse TL==32 orelse TL==64 ->
  %io:format("T ~p tl ~p~n",[Type,TL]),
  <<Tag:TL,_/binary>>=Bin,
  TagFormat="0b~"++integer_to_list(TL)++".2.0B",
  #{type=>Type,
    btag=>iolist_to_binary(io_lib:format(TagFormat,[Tag]))
   };
 
format(Type, TL, LL, Bin) when TL==8 orelse TL==16 orelse TL==32 orelse TL==64 ->
  <<Tag:TL,Len:LL,Str/binary>>=Bin,
  TagFormat="0b~"++integer_to_list(TL)++".2.0B",
  LenFormat="0b~"++integer_to_list(LL)++".2.0B",
  #{type=>Type,
    btag=>iolist_to_binary(io_lib:format(TagFormat,[Tag])),
    blen=>iolist_to_binary(io_lib:format(LenFormat,[Len])),
    len=>Len,
    int=>Str
   }.
  %io_lib:format(":~s ~B ~b",[ Type, TL, LL]).

recv() ->
  receive {d,Depth,Type,Bin, TagLen, LenLen} ->
            D=format(Type, TagLen, LenLen, Bin),
%            io:format("~"++integer_to_list(Depth*3)++"s ~p~n",
%                      ["", D#{bin=>hex:encode(Bin),depth=>Depth}]),
            [D#{bin=>hex:encode(Bin),depth=>Depth}|recv()]
  after 0 ->
          []
  end.

chlast(List,New) ->
  {Pre,_}=lists:split(length(List)-1,List),
  Pre++[New].

path2str(Path) ->
  iolist_to_binary(
    lists:join(".",
               lists:map(
                 fun({mapk,Type}) when is_atom(Type) ->
                     io_lib:format("{?~s}",[Type]);
                    ({mapk,Name}) ->
                     io_lib:format("{~s",[Name]);
                    ({mapv,Name}) ->
                     io_lib:format("{~s}",[Name]);
                    ({arr,N}) ->
                     io_lib:format("[~b]",[N]);
                    (Any) ->
                     io_lib:format("~p",[Any])
                 end, Path))).
  %iolist_to_binary(io_lib:format("~p",[Path])).

dump(DescrFun) ->
  #{r:=Res}=lists:foldl(
    fun(#{depth:=D,type:=T}=E0,#{r:=Res,path:=Path}=_Acc) ->
        {RPx,_}=try lists:split(D,Path)
                catch error:badarg ->
                        {[],[]}
                end,
        RP=if length(RPx)==0 -> RPx;
              true ->
                case lists:last(RPx) of
                  map -> chlast(RPx,
                                if T==str ->
                                     {mapk, maps:get(str,E0)};
                                   true ->
                                     {mapk,T}
                                end);
                  mapv -> chlast(RPx,
                                 if T==str ->
                                      {mapk, maps:get(str,E0)};
                                    true ->
                                      {mapk,T}
                                 end);
                  {mapv,_} -> chlast(RPx,
                                     if T==str ->
                                          {mapk, maps:get(str,E0)};
                                        true ->
                                          {mapk,T}
                                     end);
                  {mapk,X} -> chlast(RPx,{mapv,X});
                  mapk -> chlast(RPx,mapv);
                  arr -> chlast(RPx,{arr,0});
                  {arr,X} -> chlast(RPx,{arr,X+1});
                  _ -> RPx
                end
           end,
        NewPath=RP++[T],
%        io:format("T ~7s Depth ~p 1 x ~b ~p ~n",[T,D,length(RPx),NewPath]),
        Descr=DescrFun(E0,RP),
        E=case Descr of 
            false -> 
              E0#{path=>path2str(RP)};
            {error,Txt} when is_list(Txt) -> 
              E0#{path=>path2str(RP),descr=>list_to_binary(Txt),res=>error};
            {warning,Txt} when is_list(Txt) -> 
              E0#{path=>path2str(RP),descr=>list_to_binary(Txt),res=>warning};
            _ when is_list(Descr) -> 
              E0#{path=>path2str(RP),descr=>list_to_binary(Descr),res=>ok};
            _ ->
              E0#{path=>path2str(RP),
                  descr=>iolist_to_binary(io_lib:format("~p",[Descr])),res=>error}
          end,
        #{ r=>Res++[E], path=>NewPath }
    end, #{d=>0,r=>[],path=>[]}, recv()),
  Res.


show(Tx) ->
  {Res,<<>>}=unpack_stream(Tx,0),
  %io:format("-------------~n~p~n",[Res]),
  case Res of 
    #{<<"k">>:=_} ->
      dump(fun(#{type:=T},[{mapv,<<"e">>}]) ->
               if T==map -> "ok";
                  true -> {error,"must be map"}
               end;
              (#{type:=T},[{mapv,<<"k">>}]) ->
               if T==uint -> "ok";
                  true -> {error,"must be uint"}
               end;
               (#{type:=T},[{mapv,<<"t">>}]) ->
               if T==uint -> "ok";
                  true -> {error,"must be uint"}
               end;
              (#{type:=T},[{mapv,<<"s">>}]) ->
               if T==uint -> "ok";
                  true -> {error,"must be uint"}
               end;
              (#{type:=T},[{mapv,<<"to">>}]) ->
               if T==bin -> "ok";
                  true -> {error,"must be bin"}
               end;
               (#{type:=T},[{mapv,<<"p">>}])->
               if T==arr -> "ok";
                  true -> {error, "payload must be array"}
               end;
              (#{type:=T},[{mapv,<<"p">>},{arr,_},{arr,0}]) ->
               if T==uint -> "ok";
                  true -> {error, "1st element of payload item (purpose) must be uint"}
               end;
               (#{type:=T},[{mapv,<<"p">>},{arr,_},{arr,1}]) ->
               if T==str -> "ok";
                  true -> {error, "2nd element of payload item (currency) must be string"}
               end;
              (#{type:=T},[{mapv,<<"p">>},{arr,_},{arr,2}]) ->
               if T==uint -> "ok";
                  true -> {error, "3rd element of payload item (amount) must be uint"}
               end;
              (#{type:=T},[{mapv,<<"p">>},{arr,_}])->
               if T==arr -> "ok";
                  true -> {error, "payload items must be array"}
               end;
               (#{type:=T},[{mapv,<<"f">>}]) ->
               if T==bin -> "ok";
                  true -> {error,"must be bin"}
               end;
              (#{type:=T},[{mapk,_}])->
               if T==str -> "ok";
                  true -> {error, "keys of this map must be strings"}
               end;
               (#{type:=T},[])->
               if T==map -> "ok";
                  true -> {error, "top level element must be map"}
               end;
              (E0,Path)->
               lager:notice("Body unknown element ~p: ~p~n",[Path,E0]),
               {warning, "unknown element"}
           end);
    #{<<"ver">>:=_,<<"body">>:=_} ->
      dump(fun
             (#{type:=T},[{mapv,<<"body">>}])->
               if T==bin -> "ok";
                  T==str -> {warning, "body must be binary"};
                  true -> {error, "body must be binary"}
               end;
             (#{type:=T},[{mapv,<<"sig">>}])->
               if T==map -> "ok";
                  true -> {error, "sig must be map"}
               end;
             (#{type:=T},[{mapv,<<"ver">>}])->
               if T==uint -> "ok";
                  true -> {error, "ver must be uint"}
               end;
             (#{type:=T},[{mapk,_}])->
               if T==str -> "ok";
                  true -> {error, "keys of this map must be strings"}
               end;
             (#{type:=T},[])->
               if T==map -> "ok";
                  true -> {error, "top level element must be map"}
               end;
              (E0,Path)->
               lager:notice("Container unknown element ~p: ~p",[Path,E0]),
               {warning, "unknown element"}
           end);
    _ ->
      dump(fun(_,_)->false end)
  end.

%% ATOMS
unpack_stream(<<16#C0, Rest/binary>>, Depth) ->
  ?D(atom, <<16#C0>>, 8, 0),
  {null, Rest};
unpack_stream(<<16#C2, Rest/binary>>, Depth) ->
  ?D(atom, <<16#C2>>, 8, 0),
  {false, Rest};
unpack_stream(<<16#C3, Rest/binary>>, Depth) ->
  ?D(atom, <<16#C3>>, 8, 0),
  {true, Rest};

%% Raw bytes
unpack_stream(<<16#C4, L:8/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(bin, <<16#C4,L:8/big,V:L/binary>>,8,8),
  {maybe_bin(V, Depth+1), Rest};
unpack_stream(<<16#C5, L:16/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(bin, <<16#C4,L:16/big,V:L/binary>>,8,16),
  {maybe_bin(V, Depth+1), Rest};
unpack_stream(<<16#C6, L:32/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(bin, <<16#C4,L:32/big,V:L/binary>>,8,32),
  {maybe_bin(V, Depth+1), Rest};

%% Floats
unpack_stream(<<16#CA, V:32/float-unit:1, Rest/binary>>, Depth) ->
  ?D(float32, <<16#CA, V:32/float-unit:1>>,8,32),
    {V, Rest};
unpack_stream(<<16#CA, 0:1, 16#FF:8, 0:23, Rest/binary>>, Depth) ->
  ?D(float32, <<16#CA, 0:1, 16#FF:8, 0:23>>,32,0),
    {positive_infinity, Rest};
unpack_stream(<<16#CA, 1:1, 16#FF:8, 0:23 , Rest/binary>>, Depth) ->
  ?D(float32, <<16#CA, 1:1, 16#FF:8, 0:23>>,32,0),
    {negative_infinity, Rest};
unpack_stream(<<16#CA, X:1, 16#FF:8, Y:23 , Rest/binary>>, Depth) ->
  ?D(float32, <<16#CA, X:1, 16#FF:8, Y:23>>,32,0),
    {nan, Rest};
unpack_stream(<<16#CB, V:64/float-unit:1, Rest/binary>>, Depth) ->
  ?D(float64, <<16#CB, V:64/float-unit:1>>,8,0),
    {V, Rest};
unpack_stream(<<16#CB, 0:1, 2#11111111111:11, 0:52, Rest/binary>>, Depth) ->
  ?D(float64, <<16#CB, 0:1, 2#11111111111:11, 0:52>>,64,0),
    {positive_infinity, Rest};
unpack_stream(<<16#CB, 1:1, 2#11111111111:11, 0:52 , Rest/binary>>, Depth) ->
  ?D(float64, <<16#CB, 1:1, 2#11111111111:11, 0:52>>,64,0),
    {negative_infinity, Rest};
unpack_stream(<<16#CB, X:1, 2#11111111111:11, Y:52 , Rest/binary>>, Depth) ->
  ?D(float64, <<16#CB, X:1, 2#11111111111:11, Y:52>>,64,0),
    {nan, Rest};

%% Unsigned integers
unpack_stream(<<16#CC, V:8/unsigned-integer, Rest/binary>>, Depth) ->
  ?D(uint, <<16#CC, V:8/unsigned-integer>>,8,0),
  {V, Rest};
unpack_stream(<<16#CD, V:16/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(uint, <<16#CD, V:16/big-unsigned-integer>>,8,0),
    {V, Rest};
unpack_stream(<<16#CE, V:32/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(uint, <<16#CE, V:32/big-unsigned-integer>>,8,0),
    {V, Rest};
unpack_stream(<<16#CF, V:64/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(uint, <<16#CF, V:64/big-unsigned-integer>>,8,0),
    {V, Rest};

%% Signed integers
unpack_stream(<<16#D0, V:8/signed-integer, Rest/binary>>, Depth) ->
  ?D(int, <<16#D0, V:8/signed-integer>>,8,0),
    {V, Rest};
unpack_stream(<<16#D1, V:16/big-signed-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(int, <<16#D1, V:16/big-signed-integer>>,8,0),
    {V, Rest};
unpack_stream(<<16#D2, V:32/big-signed-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(int, <<16#D2, V:32/big-signed-integer>>,8,0),
    {V, Rest};
unpack_stream(<<16#D3, V:64/big-signed-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(int, <<16#D3, V:64/big-signed-integer>>,8,0),
    {V, Rest};

%% Strings as new spec, or Raw bytes as old spec
unpack_stream(<<2#101:3, L:5, V:L/binary, Rest/binary>>, Depth) ->
  ?D(str, <<2#101:3, L:5, V:L/binary>>,3,5),
    unpack_str_or_raw(V, Depth+1, Rest);

unpack_stream(<<16#D9, L:8/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(str, <<16#D9, L:8/big-unsigned-integer-unit:1, V:L/binary>>,8,8),
    %% D9 is only for new spec
    unpack_str_or_raw(V, Depth+1, Rest);

unpack_stream(<<16#DA, L:16/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(str, <<16#DA, L:16/big-unsigned-integer-unit:1, V:L/binary>>,8,16),
    %% DA and DB, are string/binary
    unpack_str_or_raw(V, Depth+1, Rest);

unpack_stream(<<16#DB, L:32/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Depth) ->
  ?D(str, <<16#DB, L:32/big-unsigned-integer-unit:1, V:L/binary>>,8,32),
    unpack_str_or_raw(V, Depth+1, Rest);

%% Arrays
unpack_stream(<<2#1001:4, L:4, Rest/binary>>, Depth) ->
  ?D(arr, <<2#1001:4, L:4>>,4,4),
    unpack_array(Rest, L, [], Depth+1);
unpack_stream(<<16#DC, L:16/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(arr, <<16#DC, L:16/big-unsigned-integer-unit:1>>,8,16),
    unpack_array(Rest, L, [], Depth+1);
unpack_stream(<<16#DD, L:32/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(arr, <<16#DD, L:32/big-unsigned-integer-unit:1>>,8,32),
    unpack_array(Rest, L, [], Depth+1);

%% Maps
unpack_stream(<<2#1000:4, L:4, Rest/binary>>, Depth) ->
  ?D(map, <<2#1000:4, L:4>>, 4, 4),
    unpack_map(Rest, L, Depth+1);
unpack_stream(<<16#DE, L:16/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(map, <<16#DE, L:16/big-unsigned-integer-unit:1>>,8,16),
    unpack_map(Rest, L, Depth+1);
unpack_stream(<<16#DF, L:32/big-unsigned-integer-unit:1, Rest/binary>>, Depth) ->
  ?D(map, <<16#DF, L:32/big-unsigned-integer-unit:1>>,8,32),
    unpack_map(Rest, L, Depth+1);

%% Tag-encoded lengths (kept last, for speed)
%% positive int
unpack_stream(<<0:1, V:7, Rest/binary>>, Depth) -> 
  ?D(uint, <<0:1, V:7>>, 1,0),
  {V, Rest};

%% negative int
unpack_stream(<<2#111:3, V:5, Rest/binary>>, Depth) -> 
  ?D(int5, <<2#111:3, V:5>>,3,0),
  {V - 2#100000, Rest};

%% Invalid data
unpack_stream(<<16#C1, _R/binary>>, _) ->  
  throw({badarg, 16#C1});

%% for extention types

unpack_stream(_Bin, _Depth) ->
    throw(incomplete).

unpack_array(Bin, 0,   Acc, _) ->
    {lists:reverse(Acc), Bin};
unpack_array(Bin, Len, Acc, Depth) ->
    {Term, Rest} = unpack_stream(Bin, Depth),
    unpack_array(Rest, Len-1, [Term|Acc], Depth).

unpack_map(Bin, Len, Depth) ->
    %% TODO: optimize with unpack_map/4
    {Map, Rest} = unpack_map_as_proplist(Bin, Len, [], Depth),
    {maps:from_list(Map), Rest}.

unpack_map_as_proplist(Bin, 0, Acc, _) ->
    {lists:reverse(Acc), Bin};
unpack_map_as_proplist(Bin, Len, Acc, Depth) ->
    {Key, Rest} = unpack_stream(Bin, Depth),
    {Value, Rest2} = unpack_stream(Rest, Depth),
    unpack_map_as_proplist(Rest2, Len-1, [{Key,Value}|Acc], Depth).

unpack_str_or_raw(V, Depth, Rest) ->
    { maybe_bin(V, Depth), Rest}.

maybe_bin(Bin, _) ->
    Bin.

