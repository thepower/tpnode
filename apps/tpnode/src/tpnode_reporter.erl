-module(tpnode_reporter).
-export([prepare/1,prepare/3, blockinfo/1, band_info/2, encode_data/1, ensure_account/0, register/1,
        post_tx_and_wait/2]).

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

encode_data(Data) ->
    {ok,{_,Sig,_}=SS}=contract_evm_abi:parse_signature(
                        "updateData((bytes32,uint256,uint256,uint256,(bytes,uint256,uint256)[])[])"
                       ),
    FunctionSig=contract_evm_abi:sigb32(contract_evm_abi:mk_sig(SS)),
    EData=contract_evm_abi:encode_abi([Data],Sig),
    <<FunctionSig/binary,EData/binary>>.

prepare(ToContract) ->
    KeyId=case tpnode_evmrun:evm_run(ToContract,
                                     <<"node_id(bytes nodekey) returns (uint256)">>,
                                     [nodekey:get_pub()],
                                     #{ gas=>50000 }) of
              #{result:=return, decode:=[Result2]} -> Result2
          end,
    io:format("KeyID ~p~n",[KeyId]),
    if(KeyId > 0) ->
          SCH=case tpnode_evmrun:evm_run(ToContract,
                                         <<"last_height(uint256) returns (uint256)">>, [KeyId],
                                         #{ gas=>50000 }) of
                  #{result:=return, decode:=[Result]} ->
                      Result
              end,
          #{height:=LBH} = maps:get(header,blockchain:last_meta()),
          io:format("SCH ~p LBH ~p~n",[SCH,LBH]),
          {F,T}=if LBH-SCH>30 ->
                       {LBH-10,LBH-1};
                   true ->
                       {SCH,min(SCH+10,LBH-1)}
                end,
        

            
          %ToBlk=(LBH div 10) * 10,
          %FromBlk=max(LBH-30,SCH),
          prepare(ToContract,F,T);
      true ->
          nokey
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


prepare(ToContract, FromBlock, ToBlock) ->
    io:format("To ~p rom ~p to ~p~n",[ToContract, FromBlock, ToBlock]),
    {ok,Address} = get_account(),
    BI=band_info(FromBlock, ToBlock),
    Args=[encode_data(BI)],
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

