-module(genuml).

-export([bv/3, testz/1]).

bv(BLog,T1,T2) ->
  MapFun=fun(T,bv_gotblock, PL) ->
             Hash=proplists:get_value(hash, PL, <<>>),
             H=proplists:get_value(height, PL, -1),
             Sig=[ bsig2node(S) || S<- proplists:get_value(sig, PL,[]) ],
             lists:foldl(
               fun(Node,Acc1) ->
                   case Acc1 of
                     [] ->
                       [
                        {T,Node,"blockvote",
                         io_lib:format("blk ~s h=~w",[blockchain:blkid(Hash),H])},
                        {T,Node,"blockvote",
                         io_lib:format("sig for ~s",[blockchain:blkid(Hash)])}];
                     _ ->
                       [{T,Node,"blockvote",
                         io_lib:format("blk ~s h=~w",[blockchain:blkid(Hash),H])}|Acc1]
                   end
               end, [], Sig);
            (T,bv_gotsig, PL) ->
             Hash=proplists:get_value(hash, PL, <<>>),
             Sig=[ bsig2node(S) || S<- proplists:get_value(sig, PL,[]) ],
             lists:foldl(
               fun(Node,Acc1) ->
                   [{T,Node,"blockvote",io_lib:format("sig for ~s",[blockchain:blkid(Hash)])}|Acc1]
               end, [], Sig);
            (_,_,_) ->
             ignore
         end,

  {Done,Events1,MinT,MaxT}=stout_reader:fold(
    fun
      (T,_,_,Acc) when T1>0, T<T1 -> Acc;
      (T,_,_,Acc) when T2>0, T>T2 -> Acc;
      (_,_,_,{500,_,_,_}=Acc) -> Acc;
      (T,Kind, PL, {C,Acc,M1,M2}) ->
        R=MapFun(T,Kind,PL),
        if R==ignore ->
             {C,
              Acc,
              min(M1,T),
              max(M2,T)
             };
           is_list(R) ->
             {C+1,
              [Acc,R],
              min(M1,T),
              max(M2,T)
             }
        end
    end, {0,[],erlang:system_time(),0}, BLog),
  io:format("~w done T ~w ... ~w~n",[Done,MinT,MaxT]),
  Events=lists:flatten(Events1),
  Text=[
"@startuml\n",
 [ io_lib:format("~s -> ~s : ~s ~s~n",[From,To,fmt_t(T),Message]) || {T,From,To,Message} <- Events ],
"@enduml\n"
       ],
  file:write_file("x.uml", Text),
  Comp=testz(Text),
  file:write_file("x.link", ["http://www.plantuml.com/plantuml/png/",Comp]).

fmt_t(T) ->
  Sec=(T div 1000000000),
  Ms=T div 100000 rem 10000,
  {_,{H,M,S}}=calendar:gregorian_seconds_to_datetime(Sec + 62167230000),
  io_lib:format("[~2.B:~2.B:~2.B.~4.B]",[H,M,S,Ms]).

bsig2node(BSig) ->
  chainsettings:is_our_node(
  %nodekey:node_id(
    proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(BSig)))
   ).

testz(Data) ->
  Z = zlib:open(),
  ok = zlib:deflateInit(Z,default),
  Compressed = zlib:deflate(Z, Data),
  Last = zlib:deflate(Z, [], finish),
  ok = zlib:deflateEnd(Z),
  zlib:close(Z),
  enc64(list_to_binary([Compressed|Last])).

enc64(<<B1,B2,B3,Rest/binary>>) ->
  [ e3b(B1,B2,B3) | enc64(Rest) ];
enc64(<<B1,B2>>) ->
  e3b(B1,B2,0);
enc64(<<B1>>) ->
  e3b(B1,0,0);
enc64(<<>>) ->
  [].

e3b(B1,B2,B3) ->
  C1 = B1 bsr 2,
  C2 = ((B1 band 16#3) bsl 4) bor (B2 bsr 4),
  C3 = ((B2 band 16#F) bsl 2) bor (B3 bsr 6),
  C4 = B3 band 16#3F,
  [ e64(C1 band 16#3F),
    e64(C2 band 16#3F),
    e64(C3 band 16#3F),
    e64(C4 band 16#3F) ].


e64(B) when B<10 -> 48+B;
e64(B) when B-10<26 -> 65+B-10;
e64(B) when B-36<26 -> 97+B-36;
e64(B) when B-62==0 -> $-;
e64(B) when B-62==1 -> $_;
e64(_) -> $?.

