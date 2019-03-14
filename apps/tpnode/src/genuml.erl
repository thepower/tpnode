-module(genuml).

-export([bv/3, testz/1, block/3, timerange/1]).

% --------------------------------------------------------------------------------

-define(get_node(NodeKey), node_map(proplists:get_value(NodeKey, PL, File))).

-define(MAX_MESSAGES, 10000).

pkey_2_nodename(PubKey) ->
  Map = #{
        <<3,65,219,169,25,115,185,116,113,161,0,156,223,129,25,9,61,27,234,23,83,
      17,228,94,241,233,210,123,164,162,130,156,237>> => <<"c1n1">> ,
        <<2,251,28,114,92,35,34,203,58,8,252,29,42,144,44,222,58,13,64,154,47,63,
      181,113,168,93,179,93,155,116,229,204,127>> => <<"c1n2">> ,
        <<2,199,84,253,255,148,14,224,195,47,64,113,74,173,164,121,20,138,5,125,
      57,116,175,104,214,127,237,253,133,64,98,52,93>> => <<"c1n3">> ,
        <<3,2,188,230,134,142,155,28,254,103,26,96,198,128,178,96,1,52,6,127,82,
      246,85,66,183,163,183,97,47,29,63,31,17>> => <<"c1n4">> ,
        <<3,109,42,79,42,177,14,114,167,57,22,180,146,55,194,135,214,214,32,57,
      78,172,241,239,17,45,154,244,30,131,99,148,254>> => <<"c1n5">> ,
        <<2,232,21,88,88,215,8,99,163,186,150,3,117,232,135,246,245,154,86,150,
      23,13,250,185,38,59,78,81,123,134,21,134,119>> => <<"c2n1">> ,
        <<3,197,95,81,121,136,91,235,216,82,181,47,254,72,251,125,18,167,138,173,
      58,246,126,42,207,159,18,17,142,245,154,110,121>> => <<"c2n2">> ,
        <<2,185,196,77,175,93,190,68,171,108,73,48,88,199,180,8,140,21,162,24,
      102,164,224,54,170,197,140,193,16,96,216,19,110>> => <<"c2n3">> ,
        <<3,151,180,92,162,25,73,114,59,215,222,121,183,185,196,49,80,52,103,201,
      235,151,138,156,102,108,212,232,55,186,191,185,161>> => <<"c2n4">> ,
        <<3,96,42,118,32,108,76,125,104,40,97,200,138,137,3,144,155,201,78,35,
      253,231,63,202,116,72,58,33,208,148,205,131,24>> => <<"c2n5">> ,
        <<2,159,63,164,122,82,75,108,207,197,171,150,132,35,137,86,147,204,95,
      167,51,86,130,51,94,77,92,170,65,174,38,96,67>> => <<"c3n1">> ,
        <<3,202,128,118,182,125,19,45,163,209,142,139,16,225,150,179,85,50,146,
      253,251,153,236,183,165,220,191,194,191,223,53,50,239>> => <<"c3n2">> ,
        <<3,151,17,184,134,80,77,34,240,103,60,94,77,107,200,7,136,197,33,222,
      126,172,177,115,59,51,236,153,160,37,87,162,180>> => <<"c3n3">> ,
        <<3,253,125,98,67,135,69,180,85,54,11,192,146,48,170,175,42,40,38,104,
      143,232,94,208,125,133,173,236,10,176,96,51,104>> => <<"c3n4">> ,
        <<3,14,232,234,219,254,237,125,59,10,4,250,168,194,185,126,1,191,222,236,
      105,97,58,239,209,253,31,228,22,19,177,83,160>> => <<"c3n5">> ,
    
    <<3,136,180,210,63,70,93,134,25,100,128,58,112,241,185,32,166,47,126,71,
      93,192,203,142,201,234,139,217,129,115,107,96,43>> => <<"c7n1">>,
    <<3,227,110,120,248,124,44,116,77,164,240,208,98,213,195,247,82,165,54,
      57,212,119,65,75,141,128,208,100,169,19,28,255,236>> => <<"c7n2">>,
    <<3,228,98,185,86,52,78,116,42,114,248,231,124,109,133,255,99,89,165,255,
      216,194,189,229,193,14,74,158,191,164,180,188,120>> => <<"c7n3">>,
    <<2,234,93,163,72,109,240,178,128,243,238,195,136,253,252,135,105,62,7,
      90,174,103,210,231,158,43,243,192,145,28,72,57,99>> => <<"c7n4">>,
    <<2,204,191,56,154,223,238,166,236,167,157,185,195,143,110,29,120,23,
      142,84,150,144,79,144,247,48,85,213,197,138,142,14,190>> => <<"c7n5">>
  },
  maps:get(PubKey, Map, unknown_key).
  

% --------------------------------------------------------------------------------


node_map(NodeName) when is_binary(NodeName) ->
  Map = #{
    <<"node_287nRpYV">> => <<"c4n1">>,
    <<"node_3NBx74Ed">> => <<"c4n2">>,
    <<"node_28AFpshz">> => <<"c4n3">>,
    <<"log/2/uml_test_c4n3@pwr.blog">> => <<"c4n3">>,
    <<"log/2/uml_test_c4n2@pwr.blog">> => <<"c4n2">>,
    <<"log/2/uml_test_c4n1@pwr.blog">> => <<"c4n1">>,
    <<"log/3/all_testrel@ubuntu.blog">> => <<"c7n5">>,
    <<"log/3/all_testrel@scw-2775d9.blog">> => <<"c7n4">>,
    <<"log/3/all_testrel@ci.blog">> => <<"c7n3">>,
    <<"log/3/all_testrel@scw-9dafbe-c7n2.blog">> => <<"c7n2">>,
    <<"log/3/all_testrel@scw-802ea4-c7n1.blog">> => <<"c7n1">>
  },
  maps:get(NodeName, Map, NodeName);

node_map(NodeName) ->
  node_map(utils:make_binary(NodeName)).


block(BLog,T1,T2) ->
  MapFun=fun(_T,mkblock_done, PL) ->
             PL;
            (_,N,_) ->
             io:format("N ~s~n",[N]),
             ignore
         end,
  {Done,Events1,MinT,MaxT}=stout_reader:fold(
    fun
      (T,_,_,Acc) when T1>0, T<T1 -> Acc;
      (T,_,_,Acc) when T2>0, T>T2 -> Acc;
      (_,_,_,{?MAX_MESSAGES,_,_,_}=Acc) -> Acc;
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
  Events1.

% --------------------------------------------------------------------------------
tx_map(TxIds) when is_list(TxIds) ->
  State =
    case get(tx_map_state) of
      undefined -> #{ cnt => 0 };
      MapState ->
        MapState
    end,
  Sorted = lists:sort(TxIds),
  % make sure all txs already have number
  State1 =
    lists:foldl(
    fun(El, Acc) ->
      case maps:get(El, Acc, undefined) of
        undefined ->
          Cnt = maps:get(cnt, Acc, 0),
          Acc1 = maps:put(El, Cnt, Acc),
          maps:put(cnt, Cnt+1, Acc1);
        _ ->
          Acc
      end
    end,
    State,
    Sorted
  ),
  
  % save new state
  put(tx_map_state, State1),
  
  % convert tx timestamp to number
  [maps:get(TxId, State1, 0) || TxId <- TxIds].


% --------------------------------------------------------------------------------

get_renderer() ->
  fun
    (T, ck_fork, PL, File) ->
      MyNode = ?get_node(node),
      TheirNode =
        case proplists:get_value(their_node, PL, unknown) of
          unknown ->
            MyNode;
          SomeNodeName ->
            node_map(SomeNodeName)
        end,
      
      Action = proplists:get_value(action, PL, <<>>),
      Message =
        case Action of
          stop_check_n_sync ->
            Reason =
              case proplists:get_value(reason, PL, unknown) of
                unknown -> unknown;
                normal -> normal;
                _ -> "error, see crash.log"
              end,
            io_lib:format("ck_fork ~p, reason ~p", [ Action, Reason ]);
  
          sync_to_permanent ->
            Nodes =
              [ node_map(Node) || Node <- proplists:get_value(assoc_list, PL, []) ],
  
            MyHash = proplists:get_value(myhash, PL, <<>>),
            TheirHash = proplists:get_value(their_hash, PL, <<>>),
            
            io_lib:format("ck_fork ~p, my_h=~s, their_h=~s, nodes: ~s",
              [ Action,
                blockchain:blkid(MyHash),
                blockchain:blkid(TheirHash),
                lists:join(",", Nodes)
              ]
            );
  
          tmp_chosen ->
            WidestTmp = proplists:get_value(tmp, PL, unknown),
            io_lib:format("ck_fork ~p, widest_tmp=~p", [ Action, WidestTmp] );
  
          permanent_chosen ->
            HashToSync = proplists:get_value(hash, PL, <<>>),
            io_lib:format(
              "ck_fork ~p, hash=~p",
              [ Action, blockchain:blkid(HashToSync)]
            );
            
          _ ->
            io_lib:format("ck_fork ~p", [ Action ])
        end,
      
      [{T, TheirNode, MyNode, Message}];

    (T, txqueue_mkblock, PL, File) ->
      Node = ?get_node(node),
      Ids = proplists:get_value(ids, PL, []),
      Lbh = proplists:get_value(lbh, PL, <<>>),
      Message =
        io_lib:format("txqueue_mkblock tx_cnt=~p lbh=~p",
          [length(Ids), Lbh]),

      [{T, Node, Node, Message}];
  
  
    (T, txqueue_xsig, PL, File) ->
      Node = ?get_node(node),
      Ids = proplists:get_value(ids, PL, []),
      Message =
        io_lib:format("txqueue_xsig tx_cnt=~p", [length(Ids)]),
    
      [{T, Node, Node, Message}];
  
    (T, txlog, PL, File) ->
      Node = ?get_node(node),
      TxIds = proplists:get_value(ts, PL, []),
      Ts =
        lists:map(
          fun(TxId) ->
            {_,[_,_,T1]} = txpool:decode_txid(TxId),
            T1
          end,
          TxIds),
  
      Opts = proplists:get_value(options, PL, #{}),
      Where = maps:get(where, Opts, undefined),
      
      Order =
        lists:foldl(
          fun
            (El, undefined) ->
              El;
            (_, incorrect) ->
              incorrect;
            (El, PreEl) ->
              if
                El =< PreEl ->
                  incorrect;
                true ->
                  El
              end
          end,
          undefined,
          Ts
        ),
      
      OrderMsg =
        if
          is_number(Order) ->
            ok;
          true ->
            Order
        end,
      
      TsMsg = tx_map(Ts),
      
      Message =
        case Where of
          undefined ->
            io_lib:format("txlog ~p ~w", [OrderMsg, TsMsg]);
          _ ->
%%            io_lib:format("txlog ~p ~p ~w", [OrderMsg, Where, TsMsg])
  
            case OrderMsg of
              incorrect ->
                io_lib:format(
                  "txlog ~p ~p ~w ~10000p",
                  [OrderMsg, Where, TsMsg, TxIds]);
              _ ->
                io_lib:format("txlog ~p ~p ~w", [OrderMsg, Where, TsMsg])
            end
        end,

      
      
      [{T, Node, Node, Message}];
    
    (T, txqueue_prepare, PL, File) ->
      Node = ?get_node(node),
      Ids = proplists:get_value(ids, PL, []),
      Message =
        io_lib:format("txqueue_prepare tx_cnt=~p", [length(Ids)]),
    
      [{T, Node, Node, Message}];
    
    
%%    (T, txqueue_done, PL, File) ->
%%      Node = ?get_node(node),
%%      Ids = proplists:get_value(ids, PL, []),
%%      Result = proplists:get_value(result, PL, undefined),
%%      Message =
%%        io_lib:format("txqueue_done tx_cnt=~p result=~p",
%%          [length(Ids), Result]),
%%
%%      [{T, Node, Node, Message}];
%%
%%
%%    (T, txqueue_push, PL, File) ->
%%      Node = ?get_node(node),
%%      Ids = proplists:get_value(ids, PL, []),
%%      BatchNo = proplists:get_value(batch, PL, undefined),
%%      Storage = proplists:get_value(storage, PL, undefined),
%%      Message =
%%        io_lib:format("queue_push tx_cnt=~p batch_no=~p storage=~p",
%%          [length(Ids), BatchNo, Storage]),
%%
%%      [{T, Node, Node, Message}];

    (T, batchsync, PL, File) ->
      Node = ?get_node(node),
      Action = proplists:get_value(action, PL, undefined),
      BatchNo = proplists:get_value(batch, PL, undefined),

      Message =
        io_lib:format("batch_sync ~p batch_no=~p", [Action, BatchNo]),
  
      [{T, Node, Node, Message}];
      
    (T, sync_ticktimer, PL, File) ->
      Node = ?get_node(node),
      [{T, Node, Node, "sync_ticktimer", #{arrow_type => hnote}}];
    
    (T, mkblock_process, PL, File) ->
      Node = ?get_node(node),
      [{T, Node, Node, "mkblock_process"}];
    
    (T, mkblock_done, PL, File) ->
      Node = ?get_node(node_name),
      Hdr = proplists:get_value(block_hdr, PL, #{}),
      H = proplists:get_value(height, PL, -1),
      Hash = maps:get(hash, Hdr, <<>>),
      Tmp = maps:get(temporary, Hdr, unknown),
      [{T, Node, Node,
        io_lib:format("mkblock_done ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])}
      ];
    
    (T, runsync, PL, File) ->
      Node = ?get_node(node),
      Where = proplists:get_value(where, PL, -1),
      Message =
        case proplists:get_value(error, PL, unknown) of
          unknown ->
            io_lib:format("runsync ~s", [Where]);
          Error ->
            io_lib:format("runsync error ~s", [Error])
        end,
      [ {T, Node, Node, Message} ];
    
    (T, rollback, PL, File) ->
      Options = proplists:get_value(options, PL, #{}),
      MyNode =
        case maps:get(mynode, Options, unknown) of
          unknown -> ?get_node(mynode);
          CorrectNodeName -> node_map(CorrectNodeName)
        end,
      TheirNode =
        case proplists:get_value(theirnode, PL, unknown) of
          unknown ->
            MyNode;
          SomeNodeName ->
            node_map(SomeNodeName)
        end,
      
      Action = proplists:get_value(action, PL, unknown),
      Message =
        case proplists:get_value(newhash, PL, unknown) of
          unknown ->
            io_lib:format("rollback ~p", [Action]);
          Hash ->
            io_lib:format("rollback ~p hash=~s", [Action, blockchain:blkid(Hash)])
        end,
      
      [ {T, TheirNode, MyNode, Message} ];
    
    
    (T, got_new_block, PL, File) ->
      Node = ?get_node(node),
      H = proplists:get_value(height, PL, -1),
      Verify = proplists:get_value(verify, PL, -1),
      Hash = proplists:get_value(hash, PL, -1),
      
      IgnoreStr =
        case proplists:get_value(ignore, PL, undefined) of
          undefined ->
            <<>>;
          AnyStr ->
            io_lib:format("ignore=~p", [AnyStr])
        end,
      
      [{T, Node, Node,
        io_lib:format(
          "got_new_block ~s h=~w, verify=~p ~s",
          [blockchain:blkid(Hash), H, Verify, IgnoreStr]
        )}
      ];
    
    (T, sync_needed, PL, File) ->
      Hash=proplists:get_value(hash, PL, <<>>),
      H=proplists:get_value(height, PL, -1),
      S=proplists:get_value(sig, PL, 0),
      Tmp=proplists:get_value(temp, PL, -1),
      Node = ?get_node(node),
      LBlockHash = proplists:get_value(lblockhash, PL, 0),
      PHash = proplists:get_value(phash, PL, 0),
      [
        {
          T, Node, Node,
          io_lib:format(
            "sync_needed ~s h=~w:~p sig=~w lhash=~s phash=~s",
            [
              blockchain:blkid(Hash), H, Tmp, S,
              blockchain:blkid(LBlockHash), blockchain:blkid(PHash)
            ])
        }
      ];
    
    (T, forkstate, PL, File) ->
      MyNode = ?get_node(mynode),
      TheirNode =
        case proplists:get_value(theirnode, PL, undefined) of
          undefined ->
            MyNode;
          SomeNodeName ->
            node_map(SomeNodeName)
        end,
      State = proplists:get_value(state, PL, unknown),
      MyHeight = proplists:get_value(myheight, PL, unknown),
      Tmp = proplists:get_value(tmp, PL, unknown),
      
      MyMeta = proplists:get_value(mymeta, PL, #{}),
      MyPermanentHash = chainkeeper:get_permanent_hash(MyMeta),
      
      Message =
        case State of
          {fork, ForkReason} ->
            io_lib:format("fork detected, ~s, my_perm_hash=~s",
              [ForkReason, blockchain:blkid(MyPermanentHash)]);

          possible_fork ->
            ForkHash = proplists:get_value(hash, PL, unknown),
            io_lib:format("possible fork detected, hash=~p", [blockchain:blkid(ForkHash)]);

          are_we_synced ->
            io_lib:format("got are_we_synced, h=~w:~p myhash=~p",
              [MyHeight, Tmp, blockchain:blkid(MyPermanentHash)]);
            
          OtherStatus ->
            io_lib:format("fork check h=~w:~p ~s", [MyHeight, Tmp, OtherStatus])
        end,
      
      [ {T, TheirNode, MyNode, Message} ];
    
    (T, ledger_change, PL, File) ->
      Node = ?get_node(node),
      NewHash = proplists:get_value(new_hash, PL, <<>>),
      PreHash = proplists:get_value(pre_hash, PL, <<>>),
      Message = io_lib:format(
        "ledger ~s -> ~s",
        [blockchain:blkid(NewHash), blockchain:blkid(PreHash)]
      ),
      [ {T, Node, Node, Message} ];
    
    (T, inst_sync, PL, File) ->
      Node = ?get_node(node),
      Reason = proplists:get_value(reason, PL, unknown),
      Message =
        case Reason of
          block ->
            LedgerHash = proplists:get_value(lh, PL, <<>>),
            Height = proplists:get_value(height, PL, -1),
            io_lib:format(
              "sync block h=~w lhash=~s",
              [Height, blockchain:blkid(LedgerHash)]
            );
          AnyOtherReason ->
            io_lib:format("sync ~p", [AnyOtherReason])
        end,
      [ {T, Node, Node, Message} ];
    
    (T, accept_block, PL, File) ->
      Hash=proplists:get_value(hash, PL, <<>>),
      H=proplists:get_value(height, PL, -1),
      S=proplists:get_value(sig, PL, 0),
      Tmp=proplists:get_value(temp, PL, -1),
      LHActual = proplists:get_value(ledger_hash_actual, PL, unknown),
      LHChecked = proplists:get_value(ledger_hash_checked, PL, unknown),
      
      Message =
        case LHChecked of
          unknown ->
            io_lib:format(
              "accept_block ~s h=~w:~p sig=~w",
              [blockchain:blkid(Hash), H, Tmp, S]
            );
          _ ->
            io_lib:format(
              "accept_block ~s h=~w:~p sig=~w LHA=~s LHC=~s",
              [blockchain:blkid(Hash), H, Tmp, S,
                blockchain:blkid(LHActual), blockchain:blkid(LHChecked)]
            )
        end,
      
      Node = ?get_node(node),
      
      [ { T, Node, Node, Message, #{arrow_type => rnote} } ];
    
    (T, ck_sync, PL, File) ->
      Action = proplists:get_value(action, PL, unknown),
      MyHeight = proplists:get_value(myheight, PL, unknown),
      TheirHeight = proplists:get_value(theirheight, PL, unknown),
      TheirTmp = proplists:get_value(theirtmp, PL, unknown),
      MyTmp = proplists:get_value(mytmp, PL, unknown),
      
      TheirHash =
        case proplists:get_value(theirhash, PL, unknown) of
          unknown ->
            unknown;
          AnyValidHash ->
            blockchain:blkid(AnyValidHash)
        end,
      
      TheirPermanentHash =
        case proplists:get_value(theirpermhash, PL, unknown) of
          unknown ->
            unknown;
          AnyValidPermHash ->
            blockchain:blkid(AnyValidPermHash)
        end,
      
      Options = proplists:get_value(options, PL, #{}),
      
      MyNode = node_map(maps:get(theirnode, Options, File)),
      TheirNode = node_map(maps:get(mynode, Options, unknown)),
      
      TheirHashStr =
        if
          TheirHash == TheirPermanentHash ->
            io_lib:format("~s", [TheirHash]);
          true ->
            io_lib:format("~s ~s", [TheirHash, TheirPermanentHash])
        end,
      
      Message =
        if
          TheirHeight =:= unknown orelse TheirHash =:= unknown ->
            io_lib:format("ck_sync ~s my_h=~p:~p", [Action, MyHeight, MyTmp]);
          
          true ->
            io_lib:format(
              "ck_sync ~s my_h=~p:~p their_h=~p:~p ~s",
              [Action, MyHeight, MyTmp, TheirHeight, TheirTmp, TheirHashStr])
        end,
      
      [ {T, TheirNode, MyNode, Message} ];
    
    (T, bv_ready, PL, File) ->
      Hdr=proplists:get_value(header, PL, #{}),
      Hash = maps:get(hash, Hdr, <<>>),
      H = maps:get(height, Hdr, -1),
      Node = ?get_node(node),
      [
        {T, Node, Node, io_lib:format("bv_ready ~s h=~w", [hex:encode(Hash), H])}
      ];
    
    (T, bv_gotblock, PL, File) ->
      Hash = proplists:get_value(hash, PL, <<>>),
      H = proplists:get_value(height, PL, -1),
      Tmp = proplists:get_value(tmp, PL, unknown),
      OurNodeName = node_map(proplists:get_value(node_name, PL, "blockvote_" ++ File)),
      Sig = [bsig2node(S) || S <- proplists:get_value(sig, PL, [])],
      lists:foldl(
        fun(Node0, Acc1) ->
          Node = node_map(Node0),
          
          case Acc1 of
            [] ->
              [
                {T, Node, OurNodeName,
                  io_lib:format("gotblock blk ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])},
                {T, Node, OurNodeName,
                  io_lib:format("gotblock sig for ~s", [blockchain:blkid(Hash)])}];
            _ ->
              [{T, Node, OurNodeName,
                io_lib:format("gotblock blk ~s h=~w:~p", [blockchain:blkid(Hash), H, Tmp])} | Acc1]
          end
        end, [], Sig);
    
    (T, bv_gotsig, PL, File) ->
      Hash = proplists:get_value(hash, PL, <<>>),
      Sig = [bsig2node(S) || S <- proplists:get_value(sig, PL, [])],
      OurNodeName = node_map(proplists:get_value(node_name, PL, "blockvote_" ++ File)),
      
      lists:foldl(
        fun(Node, Acc1) ->
          [
            {T, node_map(Node), OurNodeName,
              io_lib:format("gotsig sig for ~s", [blockchain:blkid(Hash)])} | Acc1]
        end, [], Sig);
    (_, _, _, _) ->
      ignore
  end.

% --------------------------------------------------------------------------------

timerange(BLog) ->
  Renderer = get_renderer(),
  
  FFun =
    fun
      (T, _Kind, _PL, {C, M1, M2, EventTimeList}, _File) ->
        {
          C + 1,
          min(M1, T),
          max(M2, T),
          
          case Renderer(T, _Kind, _PL, _File) of
            ignore ->
              EventTimeList;
            _ ->
              EventTimeList ++ [T]
          end
        }
    end,
  
  {Done, MinT, MaxT, LastEvList} =
    case BLog of
      [[_ | _] | _] ->
        stout_reader:mfold(FFun, {0, erlang:system_time(), 0, []}, BLog);
      _ ->
        stout_reader:fold(FFun, {0, erlang:system_time(), 0, []}, BLog)
    end,
  
  io:format("~w events T ~w ... ~w~n", [Done, MinT, MaxT]),
  
  if
    length(LastEvList) > ?MAX_MESSAGES ->
      {_, Trimmed} = lists:split(length(LastEvList) - ?MAX_MESSAGES, lists:sort(LastEvList)),
      io:format(
        "last ~w events T ~w, ~w~n",
        [length(Trimmed), lists:min(Trimmed), lists:max(Trimmed)]
      );
    
    true -> ok
  end,
  
  ok.
  

% --------------------------------------------------------------------------------

bv(BLog, T1, T2) ->
  MapFun = get_renderer(),
  FFun =
    fun
      (T, _, _, Acc, _) when T1 > 0, T < T1 -> Acc;
      (T, _, _, Acc, _) when T2 > 0, T > T2 -> Acc;
      %(_, _, _, {?MAX_MESSAGES, _, _, _} = Acc, _) -> Acc;
      (T, Kind, PL, {C, Acc, M1, M2}, File) ->
        R = MapFun(T, Kind, PL, File),
        if R == ignore ->
          {C,
            Acc,
            M1,
            M2
          };
          is_list(R) ->
            {C + 1,
              [Acc, R],
              min(M1, T),
              max(M2, T)
            }
        end
    end,


  {Done, Events1, MinT, MaxT} =
    case BLog of
      [[_ | _] | _] ->
        stout_reader:mfold(FFun, {0, [], erlang:system_time(), 0}, BLog);
      _ ->
        stout_reader:fold(FFun, {0, [], erlang:system_time(), 0}, BLog)
    end,

  io:format("~w done T ~w ... ~w~n", [Done, MinT, MaxT]),
  Events = lists:flatten(Events1),
  
  Formater =
    fun
      ({TimestampData, FromData, ToData, MessageData, #{arrow_type := hnote}}) when FromData =:= ToData ->
        io_lib:format("hnote over ~s : ~s ~s~n", [FromData, fmt_t(TimestampData), MessageData]);

      ({TimestampData, FromData, ToData, MessageData, #{arrow_type := rnote}}) when FromData =:= ToData ->
        io_lib:format("rnote over ~s : ~s ~s~n", [FromData, fmt_t(TimestampData), MessageData]);
  
      ({TimestampData, FromData, ToData, MessageData}) ->
        io_lib:format("~s -> ~s : ~s ~s~n", [FromData, ToData, fmt_t(TimestampData), MessageData]);
    
      (InvalidEvent) ->
        io:format("invalid event: ~p~n", [InvalidEvent])
    end,
  
  FormatedEvents = [ Formater(Event) || Event <- Events],
  events_writer(FormatedEvents).

%%  Text = [
%%    "@startuml\n",
%%    [ Formater(Event) || Event <- Events],
%%    "@enduml\n"
%%  ],
%%  file:write_file("x.uml", Text).
%%  Comp = testz(Text),
%%  file:write_file("x.link", ["http://www.plantuml.com/plantuml/png/", Comp]).

% --------------------------------------------------------------------------------
write_events_to_file(FormatedEvents, Filename) ->
  Text = [
    "@startuml\n",
    FormatedEvents,
    "@enduml\n"
  ],
  file:write_file(Filename, Text).

events_writer(FormatedEvents) ->
  events_writer(FormatedEvents, 0).

events_writer(FormatedEvents, FileNo) ->
  case length(FormatedEvents) of
    EvCnt when EvCnt > ?MAX_MESSAGES ->
      {Events1, EventsTail} = lists:split(?MAX_MESSAGES, FormatedEvents),
      write_events_to_file(Events1, "x_" ++ integer_to_list(FileNo) ++ ".uml"),
      events_writer(EventsTail, FileNo+1);
    _ ->
      write_events_to_file(FormatedEvents, "x_" ++ integer_to_list(FileNo) ++ ".uml")
  end.


% --------------------------------------------------------------------------------

fmt_t(T) ->
%%  io:format("T2: ~p~n", [T]),
  Sec=(T div 1000000000),
  Ms=T div 100000 rem 10000,
  {_,{H,M,S}}=calendar:gregorian_seconds_to_datetime(Sec + 62167230000),
  io_lib:format("[~2..0B:~2..0B:~2..0B.~4..0B]",[H,M,S,Ms]).

% --------------------------------------------------------------------------------

bsig2node(BSig) ->
  pkey_2_nodename(
  %nodekey:node_id(
    proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(BSig)))
   ).
%%chainsettings:is_our_node(
%%%nodekey:node_id(
%%proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(BSig)))
%%).

% --------------------------------------------------------------------------------

testz(Data) ->
  Z = zlib:open(),
  ok = zlib:deflateInit(Z,default),
  Compressed = zlib:deflate(Z, Data),
  Last = zlib:deflate(Z, [], finish),
  ok = zlib:deflateEnd(Z),
  zlib:close(Z),
  enc64(list_to_binary([Compressed|Last])).

% --------------------------------------------------------------------------------

enc64(<<B1,B2,B3,Rest/binary>>) ->
  [ e3b(B1,B2,B3) | enc64(Rest) ];
enc64(<<B1,B2>>) ->
  e3b(B1,B2,0);
enc64(<<B1>>) ->
  e3b(B1,0,0);
enc64(<<>>) ->
  [].

% --------------------------------------------------------------------------------

e3b(B1,B2,B3) ->
  C1 = B1 bsr 2,
  C2 = ((B1 band 16#3) bsl 4) bor (B2 bsr 4),
  C3 = ((B2 band 16#F) bsl 2) bor (B3 bsr 6),
  C4 = B3 band 16#3F,
  [ e64(C1 band 16#3F),
    e64(C2 band 16#3F),
    e64(C3 band 16#3F),
    e64(C4 band 16#3F) ].

% --------------------------------------------------------------------------------

e64(B) when B<10 -> 48+B;
e64(B) when B-10<26 -> 65+B-10;
e64(B) when B-36<26 -> 97+B-36;
e64(B) when B-62==0 -> $-;
e64(B) when B-62==1 -> $_;
e64(_) -> $?.

