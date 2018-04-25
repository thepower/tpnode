-module(scratchpad).
-compile(export_all).
-compile(nowarn_export_all).

node_id() ->
    nodekey:node_id().

i2g(I) when I<65536 ->
    L2=I rem 26,
    L3=I div 26,
    <<($A+L3), ($A+L2)>>.

geninvite(N,Secret) ->
  P= <<"Power_",(i2g(N))/binary>>,
  iolist_to_binary(
    [P,io_lib:format("~6..0B",[erlang:crc32(<<Secret/binary,P/binary>>) rem 1000000])]
   ).

sign(Message) ->
    PKey=nodekey:get_priv(),
    Msg32 = crypto:hash(sha256, Message),
    Sig = tpecdsa:secp256k1_ecdsa_sign(Msg32, PKey, default, <<>>),
    Pub=tpecdsa:secp256k1_ec_pubkey_create(PKey, true),
    <<Pub/binary, Sig/binary, Message/binary>>.

verify(<<Public:33/binary, Sig:71/binary, Message/binary>>) ->
    {ok, TrustedKeys}=application:get_env(tpnode, trusted_keys),
    Found=lists:foldl(
      fun(_, true) -> true;
         (HexKey, false) ->
              Pub=hex:parse(HexKey),
              Pub == Public
      end, false, TrustedKeys),
    Msg32 = crypto:hash(sha256, Message),
    {Found, tpecdsa:secp256k1_ecdsa_verify(Msg32, Sig, Public)}.


gentx(BFrom, BTo, Amount, HPrivKey) when is_binary(BFrom)->
    From=lists:filter(
           fun(A) when A>=$0 andalso $9>=A -> true;
              (A) when A>=$a andalso $z>=A -> true;
              (A) when A>=$A andalso $Z>=A -> true;
              (_) -> false
           end, binary_to_list(BFrom)),
    To=re:replace(binary_to_list(BTo), <<" ">>, "", [global, {return, binary}]),
    lager:info("From ~p to ~p", [From, To]),
    Cur= <<"FTT">>,
    inets:start(),
    C=try
          {ok, {{_HTTP11, 200, _OK}, _Headers, Body}}=
          httpc:request(get,
												{"http://127.0.0.1:43280/api/address/" ++ From, []},
												[],
												[{body_format, binary}]),
          #{<<"info">>:=C1}=jsx:decode(Body, [return_maps]),
          C1
      catch _:_ ->
                #{
              <<"amount">> => #{},
              <<"seq">> => 0
             }
      end,
    #{<<"seq">>:=Seq}=maps:get(Cur, C, #{<<"amount">> => 0, <<"seq">> => 0}),

    Tx=#{
      amount=>Amount,
      cur=>Cur,
      extradata=>jsx:encode(#{
                   message=><<"preved from gentx">>
                  }),
      from=>list_to_binary(From),
      to=>To,
      seq=>Seq+1,
      timestamp=>os:system_time(millisecond)
     },
    io:format("TX1 ~p.~n", [Tx]),
    NewTx=tx:sign(Tx, address:parsekey(HPrivKey)),
    io:format("TX2 ~p.~n", [NewTx]),
    BinTX=bin2hex:dbin2hex(NewTx),
    io:format("TX3 ~p.~n", [BinTX]),
    {
    tx:unpack(NewTx),
    httpc:request(post,
									{"http://127.0.0.1:43280/api/tx/new",
									 [],
									 "application/json",
									 <<"{\"tx\":\"0x", BinTX/binary, "\"}">>
									},
									[], [{body_format, binary}])
    }.

reapply_settings() ->
    PrivKey=nodekey:get_priv(),
    Patch=settings:sign(
            settings:get_patches(gen_server:call(blockchain, settings)),
            PrivKey),
    io:format("PK ~p~n", [settings:verify(Patch)]),
    {Patch,
     gen_server:call(txpool, {patch, Patch})}.

debug_gentx() ->
	From= <<128, 1, 64, 0, 1, 0, 0, 5>>,
	To= <<128, 1, 64, 0, 1, 0, 0, 6>>,
	Amount=1,
	TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	lager:info("From ~p to ~p", [From, To]),
	Cur= <<"FTT">>,
	inets:start(),
	C=try
			{ok, {{_HTTP11, 200, _OK}, _Headers, Body}}=
			httpc:request(get,
										{"http://127.0.0.1:43382/api/address/" ++ From, []},
										[],
										[{body_format, binary}]),
			#{<<"info">>:=C1}=jsx:decode(Body, [return_maps]),
			C1
		catch _:_ ->
						#{
						<<"amount">> => #{},
						<<"seq">> => 0
					 }
		end,
	#{<<"seq">>:=Seq}=maps:get(Cur, C, #{<<"amount">> => 0, <<"seq">> => 0}),

	Tx=#{
		amount=>Amount,
		cur=>Cur,
		extradata=>jsx:encode(#{
								 message=><<"preved from gentx">>
								}),
		from=>From,
		to=>To,
		seq=>Seq+1,
		timestamp=>os:system_time(millisecond)
	 },
	NewTx=tx:sign(Tx, TestPriv),
	BinTX=bin2hex:dbin2hex(NewTx),
	{
	 tx:unpack(NewTx),
	 httpc:request(post,
								 {"http://127.0.0.1:43382/api/tx/debug",
									[],
									"application/json",
									<<"{\"tx\":\"0x", BinTX/binary, "\"}">>
								 },
								 [], [{body_format, binary}])
	}.

test_alloc_addr() ->
  TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
  test_alloc_addr(<<"TEST5">>,TestPriv).

test_alloc_addr(Promo,PrivKey) ->
    PubKey=tpecdsa:calc_pub(PrivKey, true),
    T=os:system_time(second),
    TX0=tx:unpack( tx:pack( #{
                     type=>register,
                     register=>PubKey,
                     timestamp=>T,
                     pow=>scratchpad:mine_sha512(<<Promo/binary," ",(integer_to_binary(T))/binary," ">>,0,24)
                    })),
    TX0.
    %gen_server:call(txpool, {register, TX0})

test_xchain_tx(ToChain) ->
    TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
    From= <<128, 1, 64, 0, 1, 0, 0, 1>>,
    To=naddress:construct_public(10, ToChain, 1),
    Cur= <<"FTT">>,
    Seq=bal:get(seq, ledger:get(From)),
    Tx=#{
      amount=>10,
      cur=>Cur,
      extradata=>jsx:encode(#{ message=><<"preved from test_xchain_tx to ",
                                          (naddress:encode(To))/binary>> }),
      from=>From,
      to=>To,
      seq=>Seq+1,
      timestamp=>os:system_time(millisecond)
     },
    io:format("TX1 ~p.~n", [Tx]),
    NewTx=tx:sign(Tx, TestPriv),
    io:format("TX2 ~p.~n", [NewTx]),
    BinTX=bin2hex:dbin2hex(NewTx),
    io:format("TX3 ~p.~n", [BinTX]),
    {
    tx:unpack(NewTx),
    txpool:new_tx(NewTx)
    }.

test_add_endless(Address, Cur) ->
    PrivKey=nodekey:get_priv(),
    MyChain=blockchain:chain(),
    true=is_integer(MyChain),
    Patch=settings:sign(
            settings:dmp(
              settings:mp(
                [
                 #{t=>set, p=>[current, endless, Address, Cur], v=>true}
                ])),
      PrivKey),
    io:format("PK ~p~n", [settings:verify(Patch)]),
    {Patch,
    gen_server:call(txpool, {patch, Patch})
    }.

test_fee_settings() ->
	PrivKey=nodekey:get_priv(),
	MyChain=blockchain:chain(),
	true=is_integer(MyChain),
	Patch=settings:sign(
					settings:dmp(
						settings:mp(
							[
							 #{t=>set, p=>[current, fee, params, <<"feeaddr">>], v=><<128, 1, 64, 0, 1, 0, 0, 4>>},
							 #{t=>set, p=>[current, fee, params, <<"tipaddr">>], v=><<128, 1, 64, 0, 1, 0, 0, 4>>},
							 #{t=>set, p=>[current, fee, params, <<"notip">>], v=>0},
							 #{t=>set, p=>[current, fee, <<"FTT">>, <<"base">>], v=>trunc(1.0e7)},
							 #{t=>set, p=>[current, fee, <<"FTT">>, <<"baseextra">>], v=>64},
							 #{t=>set, p=>[current, fee, <<"FTT">>, <<"kb">>], v=>trunc(1.0e9)},
							 #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n1">>], v=><<160, 0, 0, 0, 0, 0, 1, 1>>},
							 #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n2">>], v=><<160, 0, 0, 0, 0, 0, 1, 2>>},
							 #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n3">>], v=><<160, 0, 0, 0, 0, 0, 1, 3>>}
							])),
					PrivKey),
	io:format("PK ~p~n", [settings:verify(Patch)]),
	{Patch,
	 gen_server:call(txpool, {patch, Patch})
	}.

test_gen_invites_patch(PowDiff,From,To,Secret) ->
  settings:dmp(
    settings:mp(
      [
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"diff">>], v=>PowDiff},
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"invite">>], v=>1},
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"cleanpow">>], v=>1}
      ]++lists:map(
           fun(N) ->
               Code=geninvite(N,Secret),
               io:format("~s~n",[Code]),
               #{t=><<"list_add">>, p=>[<<"current">>, <<"register">>, <<"invites">>], 
                 v=>crypto:hash(md5,Code)
                }
           end, lists:seq(From,To)))).

get_all_nodes_keys(Wildcard) ->
  lists:filtermap(
    fun(Filename) ->
        try
          {ok,E}=file:consult(Filename),
          case proplists:get_value(privkey,E) of
            undefined -> false;
            Val -> {true, hex:decode(Val)}
          end
        catch _:_ ->
                false
        end
    end, filelib:wildcard(Wildcard)).

sign_patch(Patch) ->
  sign_patch(Patch, "c1*.config").

sign_patch(Patch, Wildcard) ->
  PrivKeys=lists:usort([nodekey:get_priv()|get_all_nodes_keys(Wildcard)]),
  lists:foldl(
    fun(Key,Acc) ->
        settings:sign(Acc,Key)
    end, Patch, PrivKeys).

test_reg_invites() ->
  Patch=sign_patch(
          settings:dmp(
            settings:mp(
              [
               #{t=>set, p=>[<<"current">>, <<"register">>, <<"diff">>], v=>16},
               #{t=>set, p=>[<<"current">>, <<"register">>, <<"invite">>], v=>1},
               #{t=>set, p=>[<<"current">>, <<"register">>, <<"cleanpow">>], v=>1},
               #{t=><<"list_add">>, p=>[<<"current">>, <<"register">>, <<"invites">>], 
                 v=>crypto:hash(md5,<<"TEST1">>)
                },
               #{t=><<"list_add">>, p=>[<<"current">>, <<"register">>, <<"invites">>], 
                 v=>crypto:hash(md5,<<"TEST2">>)
                },
               #{t=><<"list_add">>, p=>[<<"current">>, <<"register">>, <<"invites">>], 
                 v=>crypto:hash(md5,<<"TEST3">>)
                }
              ]))),
  %    io:format("PK ~p~n", [settings:verify(Patch)]),
  { 
   Patch,
   gen_server:call(txpool, {patch, Patch})}.

test_alloc_block() ->
    PrivKey=nodekey:get_priv(),
    MyChain=blockchain:chain(),
    true=is_integer(MyChain),
    Patch=settings:sign(
            settings:dmp(
              settings:mp(
                [
                 #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
                 #{t=>set, p=>[current, allocblock, group], v=>10},
                 #{t=>set, p=>[current, allocblock, block], v=>MyChain},
                 #{t=>set, p=>[current, allocblock, last], v=>0}
                ])),
      PrivKey),
    io:format("PK ~p~n", [settings:verify(Patch)]),
    {Patch,
    gen_server:call(txpool, {patch, Patch})
    }.

take_nft_contract(Address) ->
	TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	From= <<128, 1, 64, 0, 1, 0, 0, 5>>,
	Seq=bal:get(seq, ledger:get(From)),
	DeployTX=tx:unpack(
			   tx:sign(
				 #{
				 from=>From,
				 to=>From,
				 amount=>0,
				 cur=><<"FTT">>,
				 extradata=>jsx:encode(#{
											fee=>100000000,
											feecur=><<"FTT">>,
											nft_to=>naddress:encode(Address),
											nft_val=><<1:64/big>>
										 }),
				 seq=>Seq+1,
				 timestamp=>os:system_time(millisecond)
				}, TestPriv)
			  ),
	{DeployTX,
	 txpool:new_tx(DeployTX)
	}.


deploy_nft_contract() ->
	TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	DeployTX=tx:unpack(
			   tx:sign(
				 #{
				 from=><<128, 1, 64, 0, 1, 0, 0, 5>>,
				 deploy=><<"nft">>,
				 code=>erlang:term_to_binary(#{
								 owner=> <<128, 1, 64, 0, 1, 0, 0, 5>>,
								 token=> <<"NFTEST">>
								}),
				 seq=>1,
				 timestamp=>os:system_time(millisecond)
				}, TestPriv)
			  ),
	{DeployTX,
	 txpool:new_tx(DeployTX)
	}.



deploy_fee_contract() ->
	TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	DeployTX=tx:unpack(
			   tx:sign(
				 #{
				 from=><<128, 1, 64, 0, 1, 0, 0, 4>>,
				 deploy=><<"chainfee">>,
				 code=>erlang:term_to_binary(#{
					interval=>10
				   }),
				 seq=>1,
				 timestamp=>os:system_time(millisecond)
				}, TestPriv)
			  ),
	{DeployTX,
	 txpool:new_tx(DeployTX)
	}.


test_contract_test() ->
    TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	From= <<128, 1, 64, 0, 1, 0, 0, 1>>,
	Seq=bal:get(seq, ledger:get(From)),
	DeployTX=tx:unpack(
			   tx:sign(
				 #{
				 from=>From,
				 to=><<128, 1, 64, 0, 1, 0, 0, 3>>,
				 amount=>1000000000,
				 cur=><<"FTT">>,
				 extradata=>jsx:encode(#{ fee=>10000000, feecur=><<"FTT">> }),
				 seq=>Seq+1,
				 timestamp=>os:system_time(millisecond)
				}, TestPriv)
			  ),
	{DeployTX,
	 txpool:new_tx(DeployTX)
    }.


test_deploy_contract_test() ->
    TestPriv=address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),
	DeployTX=tx:unpack(
			   tx:sign(
				 #{
				 from=><<128, 1, 64, 0, 1, 0, 0, 3>>,
				 deploy=><<"test">>,
				 code=><<>>,
				 seq=>2,
				 timestamp=>os:system_time(millisecond)
				}, TestPriv)
			  ),
	{DeployTX,
	 txpool:new_tx(DeployTX)
    }.


test_sign_patch() ->
    PrivKey=nodekey:get_priv(),
    Patch=settings:sign(
            settings:dmp(
              settings:mp(
                [
                 %       #{t=>set, p=>[globals, patchsigs], v=>2},
                 #{t=>set, p=>[chain, 0, blocktime], v=>10},
                 #{t=>set, p=>[chain, 0, allowempty], v=>0}
                 %       #{t=>list_add, p=>[chains], v=>1},
                 %       #{t=>set, p=>[chain, 1, minsig], v=>1},
                 %       #{t=>set, p=>[chain, 1, blocktime], v=>60}
                 %       #{t=>set, p=>[nodechain, <<"node4">>], v=>1 },
                 %       #{t=>set, p=>[keys, <<"node4">>], v=>
                 %         hex:parse("....") }
                ])),
      PrivKey),
    io:format("PK ~p~n", [settings:verify(Patch)]),
    {Patch,
    gen_server:call(txpool, {patch, Patch})}.

getpvt(Id) ->
    {ok, Pvt}=file:read_file(<<"tmp/addr", (integer_to_binary(Id))/binary, ".bin">>),
    Pvt.

getpub(Id) ->
    Pvt=getpvt(Id),
    Pub=tpecdsa:secp256k1_ec_pubkey_create(Pvt, false),
    Pub.

rnd_key() ->
    <<B1:8/integer, _:31/binary>>=XPriv=crypto:strong_rand_bytes(32),
    if(B1==0) -> rnd_key();
      true -> XPriv
    end.

crypto() ->
    %{_, XPriv}=crypto:generate_key(ecdh, crypto:ec_curve(secp256k1)),
    XPriv=rnd_key(),
    XPub=calc_pub(XPriv),
    Pub=tpecdsa:secp256k1_ec_pubkey_create(XPriv, true),
    if(Pub==XPub) -> ok;
      true ->
          io:format("~p~n", [
                            {bin2hex:dbin2hex(Pub),
                             bin2hex:dbin2hex(XPub)}
                           ]),
          false
    end.

calc_pub(Priv) ->
    case crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv) of
        {XPub, Priv} ->
            tpecdsa:minify(XPub);
        {_XPub, XPriv} ->
            lager:error_unsafe("Priv mismatch ~n~s~n~s",
                               [
                                bin2hex:dbin2hex(Priv),
                                bin2hex:dbin2hex(XPriv)
                               ]),
            error
    end.


sign1(Message) ->
    PrivKey=nodekey:get_priv(),
    Sig = tpecdsa:secp256k1_ecdsa_sign(Message, PrivKey, default, <<>>),
    Pub=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
    <<(size(Pub)):8/integer, (size(Sig)):8/integer, Pub/binary, Sig/binary, Message/binary>>.

sign2(Message) ->
    PrivKey=nodekey:get_priv(),
    Sig = crypto:sign(ecdsa, sha256, Message, [PrivKey, crypto:ec_curve(secp256k1)]),
    {Pub, PrivKey}=crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), PrivKey),
    <<(size(Pub)):8/integer, (size(Sig)):8/integer, Pub/binary, Sig/binary, Message/binary>>.

check(<<PubLen:8/integer, SigLen:8/integer, Rest/binary>>) ->
    <<Pub:PubLen/binary, Sig:SigLen/binary, Message/binary>>=Rest,
    {Pub, Sig, Message}.

verify1(<<PubLen:8/integer, SigLen:8/integer, Rest/binary>>) ->
    <<Public:PubLen/binary, Sig:SigLen/binary, Message/binary>>=Rest,
    {ok, TrustedKeys}=application:get_env(tpnode, trusted_keys),
    Found=lists:foldl(
      fun(_, true) -> true;
         (HexKey, false) ->
              Pub=hex:parse(HexKey),
              Pub == Public
      end, false, TrustedKeys),
    {Found, tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Public)}.

verify2(<<PubLen:8/integer, SigLen:8/integer, Rest/binary>>) ->
    <<Public:PubLen/binary, Sig:SigLen/binary, Message/binary>>=Rest,
    {ok, TrustedKeys}=application:get_env(tpnode, trusted_keys),
    Found=lists:foldl(
      fun(_, true) -> true;
         (HexKey, false) ->
              Pub=hex:parse(HexKey),
              Pub == Public
      end, false, TrustedKeys),
    {Found, crypto:verify(ecdsa, sha256, Message, Sig, [Public, crypto:ec_curve(secp256k1)])}.

test_pack_unpack(BlkID) ->
  B1=gen_server:call(blockchain, {get_block, BlkID}),
  B2=block:unpack(block:pack(B1)),
  file:write_file("tmp/pack_unpack_orig.txt", io_lib:format("~p.~n", [B1])),
  file:write_file("tmp/pack_unpack_pack.txt", io_lib:format("~p.~n", [B2])),
  B1==B2.

gen_pvt_keys(N) ->
	case file:read_file("pkeys.tmp") of
		{error, enoent} -> ok;
		{ok, _} -> throw("pkeys.tmp exists")
	end,
	PKeys=lists:foldl(
	  fun(_, Acc) ->
			  PKey=tpecdsa:generate_priv(),
			  PubKey=tpecdsa:calc_pub(PKey, true),
			  TX0=tx:unpack( tx:pack( #{ type=>register, register=>PubKey })),
			  gen_server:call(txpool, {register, TX0}),
			  [PKey|Acc]
	  end, [], lists:seq(1, N)),
	file:write_file("pkeys.tmp", io_lib:format("~p.~n", [PKeys])).

gen_pvt_addrs() ->
	{ok, [L]} = file:consult("pkeys.tmp"),
	Ledger=gen_server:call(ledger, keys),
	LL=lists:foldl(
		 fun(PKey, Acc) ->
				 PubKey=tpecdsa:calc_pub(PKey, true),
				 case lists:keyfind(PubKey, 2, Ledger) of
					 false ->
						 Acc;
					 {Addr, PubKey} ->
						 [{Addr, PKey}  | Acc]
				 end
		 end, [], L),
	if length(LL) > 0 ->
		   case file:read_file("addrs.tmp") of
			   {error, enoent} -> ok;
			   {ok, _} -> throw("addrs.tmp exists")
		   end,
		   file:write_file("addrs.tmp", io_lib:format("~p.~n", [LL])),
		   file:delete("pkeys.tmp");
	   true -> error
	end.

mine_sha512(Str, Nonce, Diff) ->
  DS= <<Str/binary,(integer_to_binary(Nonce))/binary>>,
  if Nonce rem 1000000 == 0 ->
       io:format("nonce ~w~n",[Nonce]);
     true -> ok
  end,
  Act=if Diff rem 8 == 0 ->
           <<Act1:Diff/big,_/binary>>=crypto:hash(sha512,DS),
           Act1;
         true ->
           Pad=8-(Diff rem 8),
           <<Act1:Diff/big,_:Pad/big,_/binary>>=crypto:hash(sha512,DS),
           Act1
      end,
  if Act==0 ->
       DS;
     true ->
       mine_sha512(Str,Nonce+1,Diff)
  end.



