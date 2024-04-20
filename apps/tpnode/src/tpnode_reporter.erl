-module(tpnode_reporter).
-export([prepare/3, blockinfo/1, band_info/2, encode_data/1, ensure_account/0]).

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
    [ blockinfo(N) || N <- lists:seq(N1,N2) ].

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
    {ok,{_,Sig,_}}=contract_evm_abi:parse_signature(
                     "updateData((bytes32,uint256,uint256,uint256,(bytes,uint256,uint256)[])[])"
                    ),
    contract_evm_abi:encode_abi([Data],Sig).

prepare(ToContract, FromBlock, ToBlock) ->
    {ToContract,FromBlock,ToBlock}.
%    #{
%      ver=>2,
%      kind=>generic,
%      to=>ToContract,
%      call=>#{function=>"updateData((bytes32,uint256,uint256,uint256,(bytes,uint256,uint256)[])[])",args=>Args}
%     }.

ensure_account() ->
    case
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
    end of
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
            T0=tinymq:now(1),
            {ok,TxID}=txpool:new_tx(TXConstructed),
            tinymq:subscribe(TxID, T0, self() ),
            receive
                {_From, _Timestamp, Messages} ->
                    case Messages of
                        [{true,#{address := Address}}] ->
                            utils:update_cfg(myaddress,
                                             [{address,hex:encodex(Address)},
                                              {txid,TxID}]),
                        {ok, Address}
                    end
            after 20000 ->
                      {error,{'registration_timeout',TxID}}
            end
    end.




