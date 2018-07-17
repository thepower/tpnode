-module(mkblock_benchmark).
-export([benchmark/1]).

benchmark(N) ->
    Parent=crypto:hash(sha256, <<"123">>),
    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    Pub1=tpecdsa:calc_pub(Pvt1, false),
    From=address:pub2addr(0, Pub1),
    Coin= <<"FTT">>,
    Addresses=lists:map(
                fun(_) ->
                        address:pub2addr(0, crypto:strong_rand_bytes(16))
                end, lists:seq(1, N)),
    GetSettings=fun(mychain) -> 0;
                   (settings) ->
                        #{
                      chains => [0],
                      chain =>
                      #{0 => #{blocktime => 5, minsig => 2, <<"allowempty">> => 0} }
                     };
                   ({endless, Address, _Cur}) when Address==From->
                        true;
                   ({endless, _Address, _Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting, Other})
                end,
    GetAddr=fun({_Addr, Cur}) ->
                    #{amount => 54.0, cur => Cur,
                      lastblk => crypto:hash(sha256, <<"parent0">>),
                      seq => 0, t => 0};
               (_Addr) ->
                    #{<<"FTT">> =>
                      #{amount => 54.0, cur => <<"FTT">>,
                        lastblk => crypto:hash(sha256, <<"parent0">>),
                        seq => 0, t => 0}
                     }
            end,

    {_, _Res}=lists:foldl(fun(Address, {Seq, Acc}) ->
                                Tx=#{
                                  amount=>1,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{}),
                                  from=>From,
                                  to=>Address,
                                  seq=>Seq,
                                  timestamp=>os:system_time()
                                 },
                                NewTx=tx:unpack(tx:sign(Tx, Pvt1)),
                                {Seq+1,
                                 [{binary:encode_unsigned(10000+Seq), NewTx}|Acc]
                                }
                        end, {2, []}, Addresses),
    T1=erlang:system_time(),
  _=mkblock:generate_block( _Res,
            {1, Parent},
            GetSettings,
            GetAddr,
          []),

    T2=erlang:system_time(),
    (T2-T1)/1000000.


