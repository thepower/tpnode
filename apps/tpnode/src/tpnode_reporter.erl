-module(tpnode_reporter).
-export([prepare/1,prepare/2,prepare/4, blockinfo/1, band_info/2, encode_data/2, ensure_account/0, register/1,
        post_tx_and_wait/2, get_ver/0, get_iver/1, attributes/0, attributes_changed/2,
        set_attributes/2, ask_nextblock/1, id2attr/1, run/0, run/1
        ]).

-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


get_ver() ->
    {Ver,_Build}=tpnode:ver(),
    RE="^v(?<MAJ>\\d\+)\.(?<MID>\\d\+)(\.(?<MIN>\\d\+)(\-(?<PATCH>\\d\+))?)?",
    case re:run(Ver ,RE,[{capture,all_names,list}]) of
        {match,VerSeq} ->
            lists:map(
              fun("") -> 0;
                 (Int) -> list_to_integer(Int)
              end, VerSeq)
    end.

get_iver(Ver) ->
    RE="^v(?<MAJ>\\d\+)\.(?<MID>\\d\+)(\.(?<MIN>\\d\+)(\-(?<PATCH>\\d\+))?)?",
    case re:run(Ver ,RE,[{capture,all_names,list}]) of
        {match,VerSeq} ->
            lists:foldl(fun(S,A) ->
                            I=case S of
                                  "" -> 0;
                                  Int ->list_to_integer(Int)
                              end,
                                <<A/binary,I:16/big>>
                        end, <<>>, VerSeq)
    end.

run() ->
    run(#{}).

run(Opts) ->
    {ok,_Addr}=tpnode_reporter:ensure_account(),
    CS=case application:get_env(tpnode,chainstate,undefined) of
           undefined ->
               case chainsettings:by_path([<<"current">>,<<"chainstate">>]) of
                   Y when is_binary(Y) -> Y;
                   _ -> undefined
               end;
           X ->
               naddress:decode(X)
       end,
    if is_binary(CS) ->
           case tpnode_reporter:prepare(CS, Opts) of
               nokey ->
                   logger:error("Cannot report, key is not registered");
               Tx when is_map(Tx) ->
                   {ok,TxID}=gen_server:call(txpool,txid),
                   gen_server:cast(txqueue,{push_head,TxID,tx:pack(Tx)}),
                   {ok, {TxID, Tx}};
               ignore ->
                   ignore
           end;
       true ->
           no_chainstate_specified
    end.



attr2id(mine_to) -> 1;
attr2id(version) -> 2;
attr2id(Any) when is_atom(Any) ->
    logger:notice("Unknown reporter attrib name ~p",[Any]),
    false.
decode_v(mine_to, A) ->
    naddress:decode(A);
decode_v(version, A) ->
    get_iver(A).

id2attr(1) -> mine_to;
id2attr(2) -> version;
id2attr(Any) when is_integer(Any) ->
    logger:notice("Unknown reporter attrib number ~B",[Any]),
    Any.

attributes() ->
    {Ver,_Build}=tpnode:ver(),
    A0=case application:get_env(tpnode,report_attributes) of
           undefined ->
               #{version=>Ver};
           {ok,Map} ->
               Map#{version=>Ver}
       end,
    maps:fold(
      fun(K,V,A) ->
              case attr2id(K) of
                  false -> A;
                  N ->
                      [{N,decode_v(K,V)}|A]
              end
      end, [], A0).

attributes_changed(Address, Attrs) ->
    KeyId=case tpnode_evmrun:evm_run(Address,
                                     <<"node_id(bytes nodekey) returns (uint256)">>,
                                     [nodekey:get_pub()],
                                     #{ gas=>50000 }) of
              #{result:=return, decode:=[Result1]} -> Result1
          end,
    Attr=fun(I) ->
                 case tpnode_evmrun:evm_run(Address,
                                            <<"attrib(uint256,uint256) returns (uint256)">>,
                                            [KeyId,I],
                                            #{ gas=>50000 }) of
                     #{result:=return, bin:=Result2} ->
                         binary:decode_unsigned(Result2)
                 end
         end,
    lists:foldl(
      fun({K,V},A) ->
              PreVal=Attr(K),
              case binary:decode_unsigned(V) == PreVal of
                  true -> A;
                  false ->
                      [{K,V}|A]
              end
      end, [], Attrs).

set_attributes(_ToContract, []) ->
    ignore;
set_attributes(ToContract, KVs) ->
    {ok,Address} = get_account(),
    KVs1=[ [Ki, if is_integer(Vi) -> Vi;
                   is_binary(Vi) -> binary:decode_unsigned(Vi)
                end ] || {Ki, Vi} <- KVs ],
    Tx0=tx:construct_tx(#{
      ver=>2,
      kind=>generic,
      to=>ToContract,
      from=>Address,
      t=>os:system_time(millisecond),
      seq=>maps:get(seq,mledger:get(Address),0)+1,
      payload=>[],
      call=>#{function=>"set_attrib(uint256[2][])",args=>[ KVs1 ]}
     }),
    Tx=tx:sign(Tx0,nodekey:get_priv()),
    post_tx_and_wait(Tx,20000).



blockinfo(N) ->
    #{hash:=Hash,header:=#{roots:=Roots},sign:=Sigs}=Blk=blockchain_reader:get_block(N),
    MeanTime=binary:decode_unsigned(proplists:get_value(mean_time,Roots,<<0>>)),
    InstallTime=maps:get(<<"_install_t">>,Blk,0),
    [Hash,N,
     MeanTime*1000,
     InstallTime,
     [sig(S) || S <- Sigs ]
    ].

band_info(N1,N2) ->
    lists:filtermap(
      fun(N) ->
              try
                  {true,blockinfo(N)}
              catch error:_ ->
                        false
              end
      end, lists:seq(N1,N2)).
    %[ blockinfo(N) || N <- lists:seq(N1,N2) ].

sig(<<Bin/binary>>) ->
    sig(bsig:unpacksig(Bin));

sig(#{extra:=X}=A) ->
    M1=case proplists:get_value(timestamp,X) of
           undefined ->
               0;
           K1 ->
               K1*1000
       end,
    M2=case maps:get(local_data,A,undefined) of
           undefined ->
               0;
           <<64,Xb/binary>> ->
               binary:decode_unsigned(Xb)
    end,
    RPK=case proplists:get_value(pubkey,X) of
        undefined ->
            0;
        K ->
            {_,PK}=tpecdsa:cmp_pubkey(K),
            PK
    end,
    [RPK,M1,M2].

%encode_data(Data) ->
%    {ok,{_,Sig,_}=SS}=contract_evm_abi:parse_signature(
%                        "updateData((bytes32,uint256,uint256,uint256,(bytes,uint256,uint256)[])[])"
%                       ),
%    FunctionSig=contract_evm_abi:sigb32(contract_evm_abi:mk_sig(SS)),
%    EData=contract_evm_abi:encode_abi([Data],Sig),
%    <<FunctionSig/binary,EData/binary>>.

ask_nextblock(ToContract) ->
    {
    case tpnode_evmrun:evm_run(ToContract,
                               <<"next_block_on() returns (uint256)">>,
                               [],
                               #{ gas=>50000 }) of
        #{result:=return, bin:= <<Result1:256/big>>} ->
            Result1
    end,
    case tpnode_evmrun:evm_run(ToContract,
                               <<"next_report_blk() returns (uint256)">>,
                               [],
                               #{ gas=>50000 }) of
        #{result:=return, bin:= <<Result2:256/big>>} ->
            Result2
    end
    }.

encode_data(Data, Attrs) ->
    {ok,{_,Sig,_}=SS}=contract_evm_abi:parse_signature(
                        "updateData((bytes32,uint256,uint256,uint256,(bytes,uint256,uint256)[])[],uint256[2][])"
                       ),
    FunctionSig=contract_evm_abi:sigb32(contract_evm_abi:mk_sig(SS)),
    EData=contract_evm_abi:encode_abi([Data, Attrs],Sig),
    <<FunctionSig/binary,EData/binary>>.

prepare(ToContract) ->
    prepare(ToContract, #{}).
prepare(ToContract, Opts) ->
    prepare(ToContract, attributes_changed(ToContract,attributes()), Opts).

prepare(ToContract, Attributes, Opts) ->
    KeyId=case tpnode_evmrun:evm_run(ToContract,
                                     <<"node_id(bytes nodekey) returns (uint256)">>,
                                     [nodekey:get_pub()],
                                     #{ gas=>50000 }) of
              #{result:=return, decode:=[Result2]} -> Result2
          end,
    io:format("KeyID ~p~n",[KeyId]),
    if(KeyId > 0) ->
          #{height:=LBH} = maps:get(header,blockchain:last_meta()),

          {Time,Blk}=tpnode_reporter:ask_nextblock(ToContract),
          Wait=Time-os:system_time(second),
          io:format("LBH ~p wait ~p blk ~p~n",[LBH, Wait, Blk]),
          Nowait = maps:is_key(nowait,Opts),

          if(Nowait orelse Wait =< 2 orelse LBH==Blk-1) ->
                SCH=case tpnode_evmrun:evm_run(
                           ToContract,
                           <<"last_height(uint256) returns (uint256)">>, [KeyId],
                           #{ gas=>50000 }) of
                        #{result:=return, bin:= <<Result:256/big>>} ->
                            Result
                    end,
                io:format("SCH ~p LBH ~p~n",[SCH,LBH]),
                {F,T}=if LBH-SCH>30 ->
                             {LBH-10,LBH-1};
                         true ->
                             {SCH,min(SCH+10,LBH-1)}
                      end,



                %ToBlk=(LBH div 10) * 10,
                %FromBlk=max(LBH-30,SCH),
                prepare(ToContract,F,T, Attributes);
            true ->
                ignore
          end;
      true ->
          case tpnode_evmrun:evm_run(ToContract,
                                     <<"self_registration()">>, [],
                                     #{ gas=>50000 }) of
              #{result:=return, bin:= <<1:256/big>>} ->
                  {ok,Address} = get_account(),
                  Tx0=tx:construct_tx(#{
                                    ver=>2,
                                    kind=>generic,
                                    to=>ToContract,
                                    from=>Address,
                                    t=>os:system_time(millisecond),
                                    seq=>maps:get(seq,mledger:get(Address),0)+1,
                                    payload=>[],
                                    call=>#{function=>"register()",args=>[]}
                                   }),
                  tx:sign(Tx0,nodekey:get_priv());
              _Any ->
                  nokey
          end
    end.

register(ToContract) ->
    {ok,Address} = get_account(),
    %case tpnode_evmrun:evm_run(ToContract,
    %                            <<"node_id(bytes nodekey) returns (uint256)">>,
    %                            [<<(nodekey:get_pub())/binary,1>>],
    %                            #{ gas=>50000 }) of
    %     #{result:=return, decode:=[Result2]} ->
    %         Result2
    % end
    Tx0=tx:construct_tx(#{
      ver=>2,
      kind=>generic,
      to=>ToContract,
      from=>Address,
      t=>os:system_time(millisecond),
      seq=>maps:get(seq,mledger:get(Address),0)+1,
      payload=>[
               %#{purpose=>gas,amount=>100,cur=><<"FTT">>}
               ],
      call=>#{function=>"register()",args=>[]}
     }),
    %tx:rate(Tx0,fun(E) -> io:format("~p~n",[E]),
    %                      #{<<"base">>=>Base, <<"kb">>=>KB}
    %            end).
    io:format("Tx ~p~n",[Tx0]),
    Tx=tx:sign(Tx0,nodekey:get_priv()),
    post_tx_and_wait(Tx,20000).


prepare(ToContract, FromBlock, ToBlock, Attributes) ->
    io:format("To ~p rom ~p to ~p~n",[ToContract, FromBlock, ToBlock]),
    {ok,Address} = get_account(),
    BI=band_info(FromBlock, ToBlock),
    KVs1=[ [Ki, if is_integer(Vi) -> Vi;
                   is_binary(Vi) -> binary:decode_unsigned(Vi)
                end ] || {Ki, Vi} <- Attributes ],
    Args=[encode_data(BI, KVs1) ],
    tx:sign(tx:construct_tx(#{
      ver=>2,
      kind=>generic,
      to=>ToContract,
      from=>Address,
      t=>os:system_time(millisecond),
      seq=>maps:get(seq,mledger:get(Address),1)+1,
      payload=>[],
      call=>#{function=>"0x0",args=>Args}
     }),nodekey:get_priv()).

get_account() ->
    case utils:read_cfg(myaddress,undefined) of
        undefined ->
            register;
        PL ->
            case proplists:get_value(address,PL) of
                undefined ->
                    register;
                Address0 ->
                    {ok,naddress:decode(Address0)}
            end
    end.

ensure_account() ->
    case get_account() of
        {ok, Address } ->
            {ok, Address};
        register ->
            T1=#{
                 kind => register,
                 t => os:system_time(millisecond),
                 ver => 2,
                 keys => [nodekey:get_pub()]
                },
            TXConstructed=tx:sign(tx:construct_tx(T1,[{pow_diff,8}]),nodekey:get_priv()),
            case post_tx_and_wait(TXConstructed, 20000) of
                {true,#{address := Address}} ->
                    utils:update_cfg(myaddress, [{address,hex:encodex(Address)}]),
                    {ok, Address}
            end
    end.

post_tx_and_wait(TXConstructed, Timeout) ->
    T0=tinymq:now(1),
    {ok,TxID}=txpool:new_tx(TXConstructed),
    tinymq:subscribe(TxID, T0, self() ),
    receive
        {_From, _Timestamp, Messages} ->
            case Messages of
                [{true,E}] ->
                    {true, E};
                [{false,E}] ->
                    {false, E}
            end
    after Timeout ->
              {error,{'registration_timeout',TxID}}
    end.


init(_Args) ->
  {ok, #{}}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({new_block,H,T}, State) ->
    R=run(),
    ?LOG_INFO("run ~p new blk ~p ~p",[R, H, T]),
    {noreply, State};

handle_cast(_Msg, State) ->
  ?LOG_ERROR("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(_Info, State) ->
  ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

