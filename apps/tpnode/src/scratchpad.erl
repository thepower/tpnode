-module(scratchpad).
-compile(export_all).
-compile(nowarn_export_all).

node_id() ->
  nodekey:node_id().

patch_paths() ->
  [
   #{<<"t">>=><<"set">>, <<"p">>=>[<<"current">>, <<"endless">>, <<"Address">>, <<"Cur">>],
     <<"v">>=>true},
   #{t=>set, p=>[current, fee, params, <<"feeaddr">>], v=><<128, 1, 64, 0, 1, 0, 0, 4>>},
   #{t=>set, p=>[current, fee, params, <<"tipaddr">>], v=><<128, 1, 64, 0, 1, 0, 0, 4>>},
   #{t=>set, p=>[current, fee, params, <<"notip">>], v=>0},
   #{t=>set, p=>[current, fee, <<"FTT">>, <<"base">>], v=>trunc(1.0e3)},
   #{t=>set, p=>[current, fee, <<"FTT">>, <<"baseextra">>], v=>64},
   #{t=>set, p=>[current, fee, <<"FTT">>, <<"kb">>], v=>trunc(1.0e9)},
   #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n1">>], v=><<160, 0, 0, 0, 0, 0, 1, 1>>},
   #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n2">>], v=><<160, 0, 0, 0, 0, 0, 1, 2>>},
   #{t=>set, p=>[<<"current">>, <<"rewards">>, <<"c1n3">>], v=><<160, 0, 0, 0, 0, 0, 1, 3>>},

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
    },
   #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
   #{t=>set, p=>[current, allocblock, group], v=>10},
   #{t=>set, p=>[current, allocblock, block], v=>100},
   #{t=>set, p=>[current, allocblock, last], v=>0}
  ].

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
  Sig = tpecdsa:sign(Msg32, PKey),
  Pub=tpecdsa:calc_pub(PKey, true),
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
  {Found, tpecdsa:verify(Msg32, Public, Sig)}.

test_alloc_addr2(Promo) ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Pub1=tpecdsa:calc_pub(Pvt1,true),
  T1=#{
    kind => register,
    t => os:system_time(millisecond),
    ver => 2,
    inv => Promo,
    keys => [Pub1]
   },
  TXConstructed=tx:sign(tx:construct_tx(T1,[{pow_diff,8}]),Pvt1),
  %  Packed=tx:pack(TXConstructed),
  {TXConstructed,
   txpool:new_tx(TXConstructed)
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
  PrivKeys=lists:usort(get_all_nodes_keys(Wildcard)),
  lists:foldl(
    fun(Key,Acc) ->
        settings:sign(Acc,Key)
    end, Patch, PrivKeys).

getpvt(Id) ->
  {ok, Pvt}=file:read_file(<<"tmp/addr", (integer_to_binary(Id))/binary, ".bin">>),
  Pvt.

getpub(Id) ->
  Pvt=getpvt(Id),
  Pub=tpecdsa:calc_pub(Pvt, false),
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
  Pub=tpecdsa:calc_pub(XPriv, true),
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
  Sig = tpecdsa:sign(Message, PrivKey),
  Pub=tpecdsa:calc_pub(PrivKey, true),
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
  {Found, tpecdsa:verify(Message, Public, Sig)}.

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

export_pvt_to_der() ->
  file:write_file("/tmp/addr1pvt.der",<<(hex:parse("302e0201010420"))/binary,(address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>))/binary,(hex:parse("a00706052b8104000a"))/binary>>).

export_pvt_pub_to_der() ->
  file:write_file("/tmp/addr1pvt.der",<<(hex:parse("30740201010420"))/binary,(address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>))/binary,(hex:parse("a00706052b8104000aa144034200"))/binary,(tpecdsa:calc_pub(address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),false))/binary>>).

export_pub_der() ->
  file:write_file("/tmp/addr1pub.der",[hex:parse("3036301006072a8648ce3d020106052b8104000a032200"),tpecdsa:calc_pub(address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>),true)]).
%openssl ecparam -name secp256k1 -genkey -text -out /tmp/k2.priv.pem
%openssl ec -in /tmp/k2.priv.pem -pubout -out /tmp/k2.pub.pem

%openssl ec -in /tmp/addr1pvt.der -inform der -pubout -outform pem -conv_form uncompressed
%openssl ec -in /tmp/addr1pvt.der -inform der -text -noout
%openssl asn1parse -inform der -in /tmp/addr1pvt.der -dump
%openssl ec -inform der -text < /tmp/addr1pvt.der > /tmp/addr1pvt.pem
%

cover_start() ->
  cover:start(nodes()),
  {true,{appl,tpnode,{appl_data,tpnode,_,_,_,Modules,_,_,_},_,_,_,_,_,_}}=application_controller:get_loaded(tpnode),
  cover:compile_beam(Modules),
  lists:map(
    fun(NodeName) ->
        rpc:call(NodeName,cover,compile_beam,[Modules])
    end, nodes()),
  cover:start(nodes()).
%  cover:compile([ proplists:get_value(source,proplists:get_value(compile,M:module_info())) || M <- Modules ]).

cover_finish() ->
  cover:flush(nodes()),
  timer:sleep(1000),
  cover:analyse_to_file([{outdir,"cover"},html]).

text_tx2reg() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  %  Pub=tpecdsa:calc_pub(Pvt1,true),
  T1=#{
    kind => register,
    t => 1530106238743,
    ver => 2
   },
  TXConstructed=tx:construct_tx(T1),
  Packed=tx:pack(tx:sign(TXConstructed,Pvt1)),
  %  [
  %   ?assertMatch({ok,#{sigverify:=#{valid:=1,invalid:=0}}}, verify(Packed, [])),
  %   ?assertMatch({ok,#{sign:=#{Pub:=_}} }, verify(Packed))
  %  ].
  Packed.

test_tx2b() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),
  T1=#{
    kind => generic,
    t => os:system_time(millisecond),
    seq => Seq+1,
    from => Addr,
    to => <<128,1,64,0,4,0,0,2>>,
    ver => 2,
    txext => #{
      <<"message">> => <<"preved">>
     },
    payload => [
                #{amount => 10,cur => <<"FTT">>,purpose => transfer}
                #{amount => 100,cur => <<"FTT">>,purpose => srcfee}
               ]
   },
  TXConstructed=tx:sign(tx:construct_tx(T1),Pvt1),
  {
   TXConstructed,
   txpool:new_tx(TXConstructed)
  }.


test_tx2_xc() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),
  T1=#{
    kind => generic,
    t => os:system_time(millisecond),
    seq => Seq+1,
    from => Addr,
    to => <<128,1,64,0,5,0,0,2>>,
    ver => 2,
    txext => #{
      <<"message">> => <<"preved">>
     },
    payload => [
                #{amount => 10,cur => <<"FTT">>,purpose => transfer}
                %#{amount => 20,cur => <<"FTT">>,purpose => srcfee}
               ]
   },
  TXConstructed=tx:sign(tx:construct_tx(T1),Pvt1),
  {
   TXConstructed,
   txpool:new_tx(TXConstructed)
  }.

sign_patchv2(Patch) ->
  sign_patchv2(Patch, "c1*.config").

sign_patchv2(Patch, Wildcard) ->
  PrivKeys=lists:usort(get_all_nodes_keys(Wildcard)),
  lists:foldl(
    fun(Key,Acc) ->
        tx:sign(Acc,Key)
    end, Patch, PrivKeys).


patch_v2() ->
  Patch=sign_patchv2(
          tx:construct_tx(
            #{kind=>patch,
              ver=>2,
              patches=>
              [
               #{t=>set,
                 p=>[<<"current">>, <<"testbranch">>, <<"test1">>],
                 v=>os:system_time(seconds)
                },
               #{t=>set,
                 p=>[<<"current">>, <<"testbranch">>, crypto:hash(sha,"preved")],
                 v=>crypto:hash(sha,"medved")
                },
               #{t=>list_add,
                 p=>[<<"current">>, <<"testbranch">>, <<"list_of_bin">>],
                 v=>crypto:hash(sha,"medved4")
                },
               #{t=>list_add,
                 p=>[<<"current">>, <<"testbranch">>, <<"list_of_bin">>],
                 v=>crypto:hash(sha,"medved5")
                },
               #{t=>list_add,
                 p=>[<<"current">>, <<"testbranch">>, <<"list_of_bin">>],
                 v=>crypto:hash(sha,"medved6")
                }
              ]
             }
           )
         ),
  {
   Patch,
   tx:verify(Patch),
   tx:unpack(tx:pack(Patch)),
   txpool:new_tx(Patch)
  }.

get_mp(URL) ->
  {ok, {{_HTTP11, 200, _OK}, Headers, Body}}=
  httpc:request(get, {URL, []}, [], [{body_format, binary}]),
  case proplists:get_value("content-type",Headers) of
    "application/msgpack" ->
      {ok, Res}=msgpack:unpack(Body),
      Res;
    "application/json" -> jsx:decode(Body, [return_maps]);
    ContentType ->
      {ContentType, Body}
  end.

get_xchain_prev(_Url, _Ptr, _StopAtH, _Chain, Acc, 0) ->
  Acc;

get_xchain_prev(_Url, _Ptr, StopAtH, _Chain, [{H,_}|_]=Acc, _Max) when StopAtH==H ->
  Acc;

get_xchain_prev(Url, Ptr, StopAtH, Chain, Acc, Max) ->
  EPtr=case Ptr of
         <<_:32/binary>> ->
           "0x"++binary_to_list(hex:encode(Ptr));
         "last"->"last"
       end,
  MP=get_mp(Url++"/xchain/api/prev/"++
            integer_to_list(Chain)++"/"++EPtr++".mp"),
  case MP of
    #{<<"pointers">>:=#{<<"pre_hash">>:=PH,
                        <<"height">>:=H}} ->
      get_xchain_prev(Url, PH, StopAtH, Chain, [{H,PH}|Acc], Max-1);
    #{<<"pointers">>:=#{<<"parent">>:=P,
                        <<"height">>:=H}} ->
      [{H,P}|Acc];
    Default ->
      [Default|Acc]
  end.

get_xchain_blocks(Url,StopAtH,Chain,Max) ->
  get_xchain_prev(Url,"last",StopAtH,Chain,[],Max).

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

test_parse_cert() ->
  {ok,PEM}=file:read_file("/tmp/knuth.cer"),
  [{'Certificate',Der,not_encrypted}|_]=public_key:pem_decode(PEM),
  OTPCert = public_key:pkix_decode_cert(Der, otp),
  OTPCert#'OTPCertificate'.tbsCertificate#'OTPTBSCertificate'.validity.

distribute(Module) ->
  MD=Module:module_info(md5),
  {Module,Code,_}=code:get_object_code(Module),
  lists:map(
    fun(Node) ->
        NM=rpc:call(Node,Module,module_info,[md5]),
        if(NM==MD) ->
            {Node, same};
          true ->
            {Node,
             NM,
             rpc:call(Node,code,load_binary,[Module,"nowhere",Code]),
             rpc:call(Node,Module,module_info,[md5])
            }
        end
    end, nodes()).

rd(Module) ->
  Changed=r(Module),
  if(Changed) ->
      distribute(Module);
    true ->
      Changed
  end.

r(Module) ->
  M0=Module:module_info(),
  PO=proplists:get_value(compile,M0),
  SRC=proplists:get_value(source,PO),

  io:format("Src ~s args ~p~n",[
		  SRC,
		  proplists:get_value(options,PO)
  ]),
	Opts=proplists:get_value(options,PO)--[{parse_transform,cth_readable_transform}],
  RC=compile:file(
       SRC,
	Opts
      ),
  code:purge(Module),
  code:delete(Module),
  M1=Module:module_info(),
  Changed=proplists:get_value(md5,M0) =/= proplists:get_value(md5,M1),
  error_logger:info_msg("Recompile ~s md5 ~p / ~p",
                        [Module,
                         proplists:get_value(md5,M0),
                         proplists:get_value(md5,M1)
                        ]),
  error_logger:info_msg("Recompile ~s from ~s changed ~s",[Module,SRC,Changed]),
  {RC,
   Changed
  }.

to_str(Arg) when is_binary(Arg) ->
  unicode:characters_to_list(Arg, utf8);
to_str(Arg) when is_atom(Arg) ->
  atom_to_list(Arg);
to_str(Arg) when is_integer(Arg) ->
  integer_to_list(Arg);
to_str(Arg) when is_list(Arg) ->
  Arg.

eval(File, Bindings0) ->
  {ok, Source} = file:read_file(File),
  Bindings=maps:fold(
             fun erl_eval:add_binding/3,
             erl_eval:new_bindings(),
             Bindings0),
  SourceStr = to_str(Source),
  {ok, Tokens, _} = erl_scan:string(SourceStr),
  {ok, Parsed} = erl_parse:parse_exprs(Tokens),
  {value, Result, _} = erl_eval:exprs(Parsed, Bindings),
  Result.

give_money() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),
  Dst=naddress:decode(<<"AA100000006710887985">>),

  TX=tx:sign(
       tx:construct_tx(#{
         ver=>2,
         kind=>generic,
         from=>Addr,
         to=>Dst,
         seq=>Seq+1,
         t=>os:system_time(millisecond),
         payload=>[
                   #{purpose=>srcfee, amount=>200100, cur=><<"FTT">>},
%                   #{purpose=>transfer, amount=>4000005000000, cur=><<"FTT">>},
                   #{purpose=>transfer, amount=>40000, cur=><<"SK">>}
                  ]
        }), Pvt1),
  {
   TX,
   txpool:new_tx(TX)
  }.


contract_deploy_info() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),

  TX=tx:sign(
       tx:construct_tx(#{
         ver=>2,
         kind=>deploy,
         from=>Addr,
         seq=>Seq+1,
         t=>os:system_time(millisecond),
         payload=>[
                   #{purpose=>srcfee, amount=>200100, cur=><<"FTT">>}
                  ],
         txext=>#{ "view"=> ["sha1:c50c64f1889d9211a32063ab166fdd2f9efcd580",
                             "https://yastatic.net/www/_/x/Q/xk8YidkhGjIGOrFm_dL5781YA.svg"
                            ]
                 }
        }), Pvt1),
  {
   TX,
   txpool:new_tx(TX)
  }.


contract_deploy() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),

  {ok, Code}=file:read_file("./examples/testcontract.wasm"),
  TX=tx:sign(
       tx:construct_tx(#{
         ver=>2,
         kind=>deploy,
         from=>Addr,
         seq=>Seq+1,
         t=>os:system_time(millisecond),
         payload=>[
                   #{purpose=>srcfee, amount=>200100, cur=><<"FTT">>},
                   #{purpose=>gas, amount=>500, cur=><<"FTT">>}
                  ],
         call=>#{function=>"init",args=>[16]},
         txext=>#{ "code"=> Code,
                   "vm" => "wasm"
                 }
        }), Pvt1),
  {
   TX,
   txpool:new_tx(TX)
  }.

contract_run() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),
  TX=tx:sign(
       tx:construct_tx(#{
         ver=>2,
         kind=>generic,
         from=>Addr,
         to=>Addr,
         call=>#{function=>"dec",args=>[1]},
         payload=>[
                   #{purpose=>gas, amount=>300, cur=><<"SK">>}, %will be used 1
                   #{purpose=>srcfee, amount=>100, cur=><<"SK">>}
                  ],
         seq=>Seq+1,
         t=>os:system_time(millisecond)
        }), Pvt1),
  TX.


contract_patch_gas() ->
  Patch=sign_patchv2(
          tx:construct_tx(
            #{kind=>patch,
              ver=>2,
              patches=>
              [
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"feeaddr">>], v=><<160,0,0,0,0,0,0,1>>},
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"tipaddr">>], v=><<160,0,0,0,0,0,0,1>>},
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"notip">>], v=>1},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>], v=>trunc(1.0e2)},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"baseextra">>], v=>64},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>], v=>trunc(1.0e3)},
               #{t=>set, p=>[<<"current">>, <<"gas">>, <<"FTT">>], v=>10000 },
               #{t=>set, p=>[<<"current">>, <<"gas">>, <<"SK">>], v=>100000 }
              ]
             }
           )
         ),
  Patch.

fee_tx2() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:decode(<<"AA100000006710887143">>),
  Seq=bal:get(seq,ledger:get(Addr)),
  T1=#{
    kind => generic,
    t => os:system_time(millisecond),
    seq => Seq+1,
    from => Addr,
    to => <<128,1,64,0,5,0,0,2>>,
    ver => 2,
    txext => #{
      <<"message">> => <<"preved">>
     },
    payload => [
                #{amount => 10,cur => <<"FTT">>,purpose => transfer}
                %#{amount => 20,cur => <<"FTT">>,purpose => srcfee}
               ]
   },
  TXConstructed=tx:sign(tx:construct_tx(T1),Pvt1),
  #{body:=B}=TXConstructed,
  {size(B),
   size(tx:pack(TXConstructed))
  }.

add_endless(Address, Cur) ->
  Patch=sign_patchv2(
          tx:construct_tx(
            #{kind=>patch,
              ver=>2,
              patches=>
              [
               #{<<"t">>=><<"set">>,
                 <<"p">>=>[<<"current">>,
                           <<"endless">>, Address, Cur],
                 <<"v">>=>true}
              ]
             }
           ),
          "../tpnode_extras/configs/c1n?.config"),
  io:format("PK ~p~n", [tx:verify(Patch)]),
  Patch.


add_ch1_fee_() ->
  Patch=sign_patchv2(
          tx:construct_tx(
            #{kind=>patch,
              ver=>2,
              patches=>
              [
               #{<<"p">> => [<<"current">>,<<"fee">>,<<"SK">>,<<"base">>], <<"t">> => <<"set">>,<<"v">> => 100},
               #{<<"p">> => [<<"current">>,<<"fee">>,<<"SK">>,<<"baseextra">>],<<"t">> => <<"set">>,<<"v">> => 100},
               #{<<"p">> => [<<"current">>,<<"fee">>,<<"SK">>,<<"kb">>], <<"t">> => <<"set">>,<<"v">> => 500}
              ]
             }
           ),
          "../tpnode_extras/configs/c1n?.config"),
  io:format("PK ~p~n", [tx:verify(Patch)]),
  Patch.


bootstrap(Chain) ->
  U="http://powernode25.westeurope.cloudapp.azure.com:43298/api/nodes/"++integer_to_list(Chain),
  {ok,{Code,_,Res}}=httpc:request(get,
                                  {U, [] },
                                  [], [{body_format, binary}]),
  case Code of
    {_,200,_} ->
      X=jsx:decode(Res, [return_maps]),
      CN=maps:get(<<"chain_nodes">>,X),
      N=hd(maps:keys(CN)),
      binary_to_list(hd(lists:filter(
                          fun(<<"http://",_/binary>>) -> true;
                             (_)->false
                          end, settings:get([N,<<"ip">>],CN)
                         )));
    true ->
      {error, Code}
  end.

post_batch(Bin) ->
  {ok,P} = application:get_env(tpnode,rpcport),
  post_batch("127.0.0.1:"++integer_to_list(P),Bin).

post_batch("http://"++Base, Bin) ->
  post_batch(Base, Bin);

post_batch(Base, Bin) ->
  {ok,{Code,_,Res}}=httpc:request(post,
                                  {"http://"++Base++"/api/tx/batch.bin",
                                   [],
                                   "binary/octet-stream",
                                   Bin
                                  },
                                  [], [{body_format, binary}]),
  io:format("~s~n",[Res]),
  Code.


post_tx(Tx) ->
  {ok,P} = application:get_env(tpnode,rpcport),
  post_tx("127.0.0.1:"++integer_to_list(P),Tx).

post_tx("http://"++Base, Tx) ->
  {ok,{Code,_,Res}}=httpc:request(post,
                                  {"http://"++Base++"/api/tx/new.bin",
                                   [],
                                   "binary/octet-stream",
                                   tx:pack(Tx)
                                  },
                                  [], [{body_format, binary}]),
  io:format("~s~n",[Res]),
  Code;

post_tx(Base, Tx) ->
  {ok,{Code,_,Res}}=httpc:request(post,
                                  {"http://"++Base++"/api/tx/new.bin",
                                   [],
                                   "binary/octet-stream",
                                   tx:pack(Tx)
                                  },
                                  [], [{body_format, binary}]),
  io:format("~s~n",[Res]),
  Code.

init_chain(ChNo) ->
  Issuer=naddress:construct_public(10,ChNo,1),

  Testers=[
           #{<<"t">>=><<"set">>, <<"p">>=>
             [<<"current">>, <<"endless">>, naddress:construct_public(10,ChNo,N), <<"SK">>], <<"v">>=>true}
           || N <- lists:seq(2,101) ],

  Patch=sign_patchv2(
          tx:construct_tx(
            #{kind=>patch,
              ver=>2,
              patches=>
              [
               #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
               #{t=>set, p=>[current, allocblock, group], v=>10},
               #{t=>set, p=>[current, allocblock, block], v=>ChNo},
               #{t=>set, p=>[current, allocblock, last], v=>0},
               #{t=><<"nonexist">>, p=>[<<"current">>, <<"fee">>, params, <<"feeaddr">>], v=>any},
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"feeaddr">>], v=>Issuer},
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"tipaddr">>], v=>Issuer},
               #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"notip">>], v=>1},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"base">>], v=>100},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"baseextra">>], v=>100},
               #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"kb">>], v=>500},
               #{t=>set, p=>[<<"current">>, <<"gas">>, <<"SK">>], v=>100 },
               #{<<"t">>=><<"set">>, <<"p">>=>[<<"current">>, <<"endless">>, Issuer, <<"SK">>], <<"v">>=>true}
               |Testers]
             }
           ),
          "../tpnode_extras/tn2/out/c"++integer_to_list(ChNo)++"n?.config"),
  Patch.

