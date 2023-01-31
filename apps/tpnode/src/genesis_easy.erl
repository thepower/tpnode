-module(genesis_easy).
-export([make_example/2,make_genesis/1]).

wrfile(Filename, Data) ->
  file:write_file(Filename, io_lib:format("~p.~n",[Data])).

make_example(ChainNo, NodesCnt) ->
  PrivKeys=[{N,tpecdsa:generate_priv(ed25519)} || N<- lists:seq(1,NodesCnt) ],
  PrivKeys2File=[ {N,hex:encode(Key)} || {N,Key} <- PrivKeys],
  wrfile("easy_chain"++(integer_to_list(ChainNo))++"_keys.txt", PrivKeys2File),
  PubKeysPatch=[
                begin
                  CN= <<"c",(integer_to_binary(ChainNo))/binary,"n",(integer_to_binary(N))/binary>>,
                [
                #{<<"p">> => [<<"keys">>,CN],
                  <<"t">> => <<"set">>,
                  <<"v">> =>tpecdsa:calc_pub(Key)},
                 #{<<"p">> => [<<"nodechain">>,CN],<<"t">> => <<"set">>,<<"v">> => ChainNo}
                ] 
                end
                || {N,Key} <- PrivKeys],
  Patch=[PubKeysPatch,
         [
                 #{<<"p">> => [<<"chains">>],<<"t">> => <<"list_add">>,<<"v">> => ChainNo},
                 #{<<"p">> => [<<"current">>,<<"chain">>,<<"blocktime">>],
                   <<"t">> => <<"set">>,<<"v">> => 2},
                 #{<<"p">> => [<<"current">>,<<"chain">>,<<"minsig">>],
                   <<"t">> => <<"set">>,<<"v">> => (NodesCnt div 2)+1},
                 #{<<"p">> => [<<"current">>,<<"chain">>,<<"allowempty">>],
                   <<"t">> => <<"set">>,<<"v">> => 0},
                 #{<<"p">> => [<<"current">>,<<"chain">>,<<"patchsigs">>],
                   <<"t">> => <<"set">>,<<"v">> => (NodesCnt div 2)+1},
                 #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"block">>],
                   <<"t">> => <<"set">>,<<"v">> => ChainNo},
                 #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"group">>],
                   <<"t">> => <<"set">>,<<"v">> => 10},
                 #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"last">>],
                   <<"t">> => <<"set">>,<<"v">> => 0},
                 #{<<"p">> => [<<"current">>,<<"endless">>,
                               naddress:construct_public(10,ChainNo,1),
                               <<"SK">>],
                   <<"t">> => <<"set">>,<<"v">> => true},
                 #{<<"p">> => [<<"current">>,<<"endless">>,
                               naddress:construct_public(10,ChainNo,1),
                               <<"TST">>],
                   <<"t">> => <<"set">>,<<"v">> => true},
                 #{<<"p">> => [<<"current">>,<<"freegas">>],
                   <<"t">> => <<"set">>,<<"v">> => 2000000},
                 #{<<"p">> => [<<"current">>,<<"gas">>,<<"SK">>],
                   <<"t">> => <<"set">>,<<"v">> => 1000},
                 #{<<"p">> => [<<"current">>,<<"nosk">>],<<"t">> => <<"set">>,<<"v">> => 1}
                ]
        ],
  LP=lists:flatten(Patch),
  %wrfile("easy_chain"++(integer_to_list(ChainNo))++"_patch.txt", LP),
  wrfile("easy_chain"++(integer_to_list(ChainNo))++"_settings.txt", settings:patch(LP,#{})).

make_genesis(ChainNo) ->
 Bals= case file:consult("easy_chain"++(integer_to_list(ChainNo))++"_bals.txt") of
         {ok,Bals0} -> maps:from_list(Bals0);
         {error,enoent} -> #{}
       end,
  {ok,[HexPrivKeys]}=file:consult("easy_chain"++(integer_to_list(ChainNo))++"_keys.txt"),
  Privs=[ hex:decode(X) || {_,X} <- HexPrivKeys ],
  %{ok,[Patch]}=file:consult("easy_chain"++(integer_to_list(ChainNo))++"_patch.txt"),
  {ok,[Tree]}=file:consult("easy_chain"++(integer_to_list(ChainNo))++"_settings.txt"),
  Patch=settings:get_patches(Tree),
  true=is_list(Patch),
  #{body:=Body}=SetTx=tx:construct_tx(#{kind=>patch, ver=>2, patches=> Patch }),
  PatchTx=lists:foldl(
    fun(Priv, A) ->
        tx:sign(A, Priv)
    end, SetTx,
    Privs),
  Settings=[ { bin2hex:dbin2hex(crypto:hash(md5,Body)), PatchTx } ],
  Blk0=block:mkblock2(
         #{ parent=><<0, 0, 0, 0, 0, 0, 0, 0>>,
            height=>0,
            txs=>[],
            bals=>Bals,
            mychain=>ChainNo,
            settings=>Settings,
            extra_roots=>[],
            sign=>[]
          }),
  Genesis=lists:foldl(
            fun(PrivKey, Acc) ->
                block:sign(
                  Acc,
                  [{timestamp, os:system_time(millisecond)}],
                  PrivKey)
            end, Blk0, Privs),
  file:write_file("easy_chain"++(integer_to_list(ChainNo))++"_genesis.txt", io_lib:format("~p.~n", [Genesis])).




