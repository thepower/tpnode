-module(mkblock_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile([export_all]).

all() -> [mkblock_test,test_xchain_inbound].
 
mkblock_test() ->
    GetSettings=fun(mychain) ->
                        0;
                   (settings) ->
                        #{
                      chains => [0,1],
                      chain =>
                      #{0 =>
                        #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                        1 => 
                        #{blocktime => 10,minsig => 1}
                       },
                      globals => #{<<"patchsigs">> => 2},
                      keys =>
                      #{
                        <<"node1">> => crypto:hash(sha256,<<"node1">>),
                        <<"node2">> => crypto:hash(sha256,<<"node2">>),
                        <<"node3">> => crypto:hash(sha256,<<"node3">>),
                        <<"node4">> => crypto:hash(sha256,<<"node4">>)
                       },
                      nodechain =>
                      #{
                        <<"node1">> => 0,
                        <<"node2">> => 0,
                        <<"node3">> => 0,
                        <<"node4">> => 1
                       }
                     };
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pvt2= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,6>>,
    Pvt3= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,7>>,
    ParentHash=crypto:hash(sha256,<<"parent">>),
    Pub1=tpecdsa:secp256k1_ec_pubkey_create(Pvt1),
    Pub2=tpecdsa:secp256k1_ec_pubkey_create(Pvt2),
    Pub3=tpecdsa:secp256k1_ec_pubkey_create(Pvt3),

    TX0=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>10,
                     cur=><<"FTT">>,
                     seq=>2,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),
    TX1=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>9000,
                     cur=><<"BAD">>,
                     seq=>3,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),

    TX2=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(1,Pub3),
                     amount=>9,
                     cur=><<"FTT">>,
                     seq=>4,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),
    #{block:=Block,
      failed:=Failed}=mkblock:generate_block(
                        [{<<"1interchain">>,TX0},
                         {<<"2invalid">>,TX1},
                         {<<"3crosschain">>,TX2}
                        ],
                        {1,ParentHash},
                        GetSettings,
                        GetAddr),
    ?assertEqual([{<<"2invalid">>,insufficient_fund}], Failed),
    ?assertEqual([<<"3crosschain">>],proplists:get_keys(maps:get(tx_proof,Block))),
    ?assertEqual([{<<"3crosschain">>,1}],maps:get(outbound,Block)),
    SignedBlock=block:sign(Block,<<1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1>>),
    file:write_file("testblk.txt", io_lib:format("~p.~n",[Block])),
    ?assertMatch({true, {_,_}},block:verify(SignedBlock)),
    maps:get(1,block:outward_mk(maps:get(outbound,Block),SignedBlock)),
    test_xchain_inbound().

%test_getaddr%({_Addr,_Cur}) -> %suitable for inbound tx
test_getaddr(_Addr) ->
    #{amount => #{
        <<"FTT">> => 110,
        <<"TST">> => 26
       },
      seq => 1,
      t => 1512047425350,
      lastblk => <<0:64>>
     }.

test_xchain_inbound() ->
    ParentHash=crypto:hash(sha256,<<"parent2">>),
    GetSettings=fun(mychain) ->
                        1;
                   (settings) ->
                        #{
                      chains => [0,1],
                      chain =>
                      #{0 =>
                        #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                        1 => 
                        #{blocktime => 10,minsig => 1}
                       },
                      globals => #{<<"patchsigs">> => 2},
                      keys =>
                      #{
                        <<"node1">> => crypto:hash(sha256,<<"node1">>),
                        <<"node2">> => crypto:hash(sha256,<<"node2">>),
                        <<"node3">> => crypto:hash(sha256,<<"node3">>),
                        <<"node4">> => crypto:hash(sha256,<<"node4">>)
                       },
                      nodechain =>
                      #{
                        <<"node1">> => 0,
                        <<"node2">> => 0,
                        <<"node3">> => 0,
                        <<"node4">> => 1
                       }
                     };
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun test_getaddr/1,
    

    BTX={<<"4F8367774366BC52BFBB1FFD203F815FB2274A871C7EF8F173C23EBA63365DCA">>,
         #{hash =>
           <<79,131,103,119,67,102,188,82,191,187,31,253,32,63,129,95,178,39,74,
             135,28,126,248,241,115,194,62,186,99,54,93,202>>,
           header =>
           #{balroot =>
             <<100,201,127,106,126,195,253,190,51,162,170,35,25,133,55,221,32,
               222,160,173,151,239,240,207,179,63,32,137,115,220,187,86>>,
             height => 125,
             parent =>
             <<18,157,196,134,44,12,188,92,159,126,22,101,109,214,84,157,29,
               48,186,246,102,32,147,74,9,174,152,43,150,227,200,70>>,
             txroot =>
             <<87,147,0,60,61,240,208,56,196,206,139,213,10,57,241,76,147,35,
               10,50,214,139,89,45,91,129,154,192,46,185,136,186>>},
           sign =>
           [#{binextra =>
              <<2,33,3,90,231,223,79,203,91,151,168,111,206,187,16,125,68,8,
                88,221,251,40,199,8,231,14,6,198,37,170,33,14,138,111,22,1,8,
                0,0,1,96,7,149,104,17,3,8,0,0,0,0,0,9,39,21>>,
              extra =>
              [{pubkey,<<3,90,231,223,79,203,91,151,168,111,206,187,16,125,
                         68,8,88,221,251,40,199,8,231,14,6,198,37,170,33,14,
                         138,111,22>>},
               {timestamp,1511955720209},
               {createduration,599829}],
              signature =>
              <<48,68,2,32,83,1,50,58,78,196,138,173,124,198,165,16,113,75,
                112,45,139,139,106,224,185,98,148,117,44,125,221,251,36,200,
                102,44,2,32,121,141,16,243,9,156,46,97,206,213,185,109,58,
                139,77,56,87,243,181,254,188,38,158,6,161,96,20,140,153,236,
                246,127>>},
            #{binextra =>
              <<2,33,2,7,131,239,103,72,81,252,233,190,212,91,73,77,131,140,
                107,95,57,79,23,91,55,221,38,165,17,242,158,31,33,57,75,1,8,0,
                0,1,96,7,149,104,13,3,8,0,0,0,0,0,7,100,47>>,
              extra =>
              [{pubkey,<<2,7,131,239,103,72,81,252,233,190,212,91,73,77,131,
                         140,107,95,57,79,23,91,55,221,38,165,17,242,158,31,
                         33,57,75>>},
               {timestamp,1511955720205},
               {createduration,484399}],
              signature =>
              <<48,69,2,33,0,193,141,201,10,158,9,186,213,138,169,40,46,147,
                87,86,95,168,105,38,14,234,0,34,175,197,245,6,179,108,247,
                66,185,2,32,66,161,36,73,11,127,38,157,73,224,110,16,206,
                248,16,93,229,161,135,160,224,96,132,45,107,198,204,205,109,
                39,117,75>>}],
           tx_proof =>
           [{<<"14FB8BB66EE28CCF-noded57D9KidJHaHxyKBqyM8T8eBRjDxRGWhZC-2944">>,
             {<<180,136,203,147,25,47,21,127,67,78,244,67,34,4,125,164,112,88,63,
                92,178,186,180,59,96,16,142,139,149,133,239,216>>,
              <<52,182,4,40,176,139,124,238,6,254,144,173,117,149,6,86,177,70,
                135,10,106,127,22,211,235,68,133,193,231,110,230,16>>}}],
           txs =>
           [{<<"14FB8BB66EE28CCF-noded57D9KidJHaHxyKBqyM8T8eBRjDxRGWhZC-2944">>,
             #{amount => 1.0,cur => <<"FTT">>,
               extradata => <<"{\"message\":\"preved from gentx\"}">>,
               from => <<"73VoBpU8Rtkyx1moAPJBgAZGcouhGXWVpD6PVjm5">>,
               outbound => 1,
               sig => #{  %incorrect signature for new format
                 <<"043E9FD2BBA07359FAA4EDC9AC53046EE530418F97ECDEA77E0E98288E6",
                   "E56178D79D6A023323B0047886DAFEAEDA1F9C05633A536C70C513AB847",
                   "99B32F20E2DD">>
                 =>
                 <<"30450221009B3E4E72F4DBD2A79762C2BE732CFB0D36B7EE3A4C4AC361E",
                 "B935EFE701BB757022033CD9752D6AB71C939F9C70C56185F7C0FDC9E79E2"
                 "6BB824B2F1722EFC687A4E">>
                },
               seq => 12,
               timestamp => 1511955715572989476,
               to => <<"75dF2XsYc5rLgovnekw7DobT7mubTQNN2M6E1kRr">>}}]}},
    #{block:=Block,
      failed:=Failed}=mkblock:generate_block(
                        [BTX],
                        {1,ParentHash},
                        GetSettings,
                        GetAddr),
    ?assertEqual([], Failed),
    #{block=>Block, failed=>Failed}.


