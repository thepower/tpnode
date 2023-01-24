%%%-------------------------------------------------------------------
%% @doc tpnode_repl_worker
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_repl_worker).
-include("include/tplog.hrl").
-author("cleverfox <devel@viruzzz.org>").
-create_date("2022-07-12").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,run/2,ws_mode/1,genesis/1]).
-export([run_worker/1]).
-export([run4test/0,run4test_mgmt/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

run_worker(Params) ->
  supervisor:start_child(
    repl_sup,
    [
     [{parent,self()}|Params]
    ]
   ).

run4test_mgmt() ->
  tpnode_repl_worker:run(
    #{
      parent=>self(),
      %protocol=>http,
      %address=>"127.0.0.1",
      %port=>49841
      protocol=>http,
      address=>"c3n1.thepower.io",
      port=>1083,
      check_genesis=>false
     },
    fun({apply_block,#{hash:=_H}=Block}) ->
        gen_server:call(mgt,{new_block, Block});
       (last_known_block) ->
        {ok,LBH}=gen_server:call(mgt,last_hash),
        LBH;
       (Any) ->
        io:format("requested ~p~n",[Any]),
        ok 
    end).


run4test() ->
  tpnode_repl_worker:run(
    #{
      parent=>self(),
      %protocol=>http,
      %address=>"127.0.0.1",
      %port=>49841
      protocol=>http,
      address=>"c104n1.thepower.io",
      port=>49842
     },
    fun({apply_block,#{hash:=_H}=Block}) ->
        gen_server:call(blockchain_updater,{new_block, Block, self()});
       (last_known_block) ->
        maps:get(hash,blockchain:last_permanent_meta());
        %blockchain:last_meta();
       (Any) ->
        io:format("requested ~p~n",[Any]),
        ok 
    end).

start_link(Sub0) when is_list(Sub0) ->
  start_link(maps:from_list(Sub0));

start_link(Sub0) when is_map(Sub0) ->
  GetFun=case maps:is_key(getfun,Sub0) of
           true ->
             maps:get(getfun,Sub0);
           false ->
             fun({apply_block,#{hash:=_H}=Block}) ->
                 gen_server:call(blockchain_updater,{new_block, Block, self()});
                (last_known_block) ->
                 maps:get(hash,blockchain:last_permanent_meta())
                 %blockchain:last_meta()
             end
         end,
  Sub=case Sub0 of
        #{uri:=URL} ->
          maps:fold(
            fun(host,V,A)    -> A#{address => V};
               (scheme,V,A)  -> A#{protocol => list_to_atom(V)};
               (port,V,A)    -> A#{port => V};
               (_,_,A)       -> A
            end,
            Sub0,
            uri_string:parse(URL)
           );
        #{protocol:=_,address:=_,port:=_} ->
          Sub0
      end,
  ?LOG_INFO("Spawning sup ~p",[Sub]),
  Pid=spawn(?MODULE,run,[maps:merge(#{parent=>self()},Sub), GetFun]),
  link(Pid),
  {ok, Pid}.

genesis(#{protocol:=_, address:=_, port:=_, pid:=Pid} = Sub) ->
  genesis(Sub, Pid);

genesis(#{protocol:=_, address:=_, port:=_} = Sub) ->
  Pid=connect(Sub),
  genesis(Sub, Pid).

genesis(#{} = _Sub, Pid) ->
  case sync_get_decode(Pid, "/api/binblock/genesis") of
    {200, _, V1} when is_map(V1)-> V1;
    _ -> throw('not matched')
  end.

connect(#{protocol:=http, address:=Ip, port:=Port, parent:=Parent}) ->
  {ok, Pid} = gun:open(Ip, Port),
  receive
    {gun_up, Pid, http} -> Pid
  after 20000 ->
          Parent ! {wrk_down, self(), up_timeout},
          gun:close(Pid),
          throw('up_timeout')
  end;

connect(#{protocol:=https, address:=Ip, port:=Port, parent:=Parent}) ->
  %CaCerts = certifi:cacerts(),

  CHC=[
       {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
      ],
  Opts=#{ transport=>tls,
          protocols => [http],
          transport_opts => [{verify, verify_peer},
                             %{cacerts, CaCerts},
                             {customize_hostname_check, CHC}
                            ]},
  {ok, Pid} = gun:open(Ip, Port, Opts),
  receive
    {gun_up, Pid, http} -> Pid
  after 20000 ->
          Parent ! {wrk_down, self(), up_timeout},
          gun:close(Pid),
          throw('up_timeout')
  end;

connect(#{protocol:=Proto, parent:=Parent}) ->
  ?LOG_ERROR("replica protocol ~p does not supported",[Proto]),
  Parent ! {wrk_down, self(), {error,badproto}},
  throw(badproto).


run(#{parent:=Parent, protocol:=_Proto, address:=Ip, port:=Port} = Sub, GetFun) ->
  ?LOG_INFO("repl client connecting to ~p ~p", [Ip, Port]),
  Pid=connect(Sub),
  try
    Genesis=case sync_get_decode(Pid, "/api/binblock/genesis") of
              {200, _, V1} when is_map(V1) -> V1;
              {404, _, _} -> throw('incompatible');
              _ -> throw('incompatible')
            end,
    case maps:get(check_genesis, Sub, undefined) of
      false ->
        ok;
      F when is_function(F)  ->
        F(Genesis);
      undefined ->
        case blockchain:rel(genesis,self) of
          #{hash:=Hash} ->
            case maps:get(hash, Genesis) == Hash of
              false ->
                file:write_file("genesis_repl.txt",
                                io_lib:format("~p.~n",[Genesis])),
                ?LOG_NOTICE("Genesis mismatch for replication. Their genesis saved in genesis_repl.txt"),
                throw('genesis_mismatch');
              true ->
                ?LOG_INFO("Genesis ok")
            end;
          _ ->
            throw('unexpected_genesis')
        end
    end,
    LastBlock=case sync_get_decode(Pid, "/api/binblock/last") of
                {200, _, V2} -> maps:with([hash,header],V2);
                Error1 ->
                  ?LOG_ERROR("Can't get last block ~p",[Error1]),
                  throw('cant_get_last')
              end,
    ?LOG_INFO("Their lastblk: ~s",[blkinfo(LastBlock)]),

    KnownBlock=GetFun(last_known_block),
    ?LOG_INFO("My lastblk: ~s",[blkinfo(KnownBlock)]),
    Parent ! {wrk_presync, self(), start},
    {ok,Sub1}=presync(Sub#{pid=>Pid,getfun=>GetFun,
                           last=>KnownBlock},
                      if KnownBlock==<<0:64>> ->
                           <<"genesis">>;
                         true ->
                           hex:encode(KnownBlock)
                      end),

    {ok,UpgradeHdrs}=upgrade(Pid),
    ?LOG_INFO("Conn upgrade hdrs: ~p",[UpgradeHdrs]),

    Cmd = msgpack:pack(#{ null=><<"subscribe">>, <<"channel">> => default}),
    ok=gun:ws_send(Pid, {binary, Cmd}),
    Parent ! {wrk_up, self(), undefined},
    self() ! alive,
    ws_mode(Sub1),
    gun:close(Pid),
    done
  catch
    throw:R ->
      Parent ! {wrk_down, self(), {error, R}},
      gun:close(Pid),
      {error, R};
    Ec:Ee:S ->
      Parent ! {wrk_down, self(), {error, other}},
      gun:close(Pid),
      ?LOG_ERROR("repl client error ~p:~p@~p",[Ec,Ee,hd(S)]),
      lists:foreach(
        fun(SE) ->
            ?LOG_ERROR("@ ~p", [SE])
        end, S)
  end.

ws_mode(#{pid:=Pid, parent:=Parent}=Sub) ->
  receive
    {'EXIT',_,shutdown} ->
      Cmd = msgpack:pack(#{null=><<"goodbye">>, <<"r">>=><<"shutdown">>}),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      exit;
    {'EXIT',_,Reason} ->
      ?LOG_ERROR("Linked process went down ~p. Giving up....",[Reason]),
      Cmd = msgpack:pack(#{null=><<"goodbye">>, <<"r">>=><<"deadparent">>}),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      exit;
    {system,{From,Tag},get_state} ->
      From ! {Tag, Sub},
      ?MODULE:ws_mode(Sub);
    {'$gen_call',{From,Tag},uri} ->
      From ! {Tag, maps:get(uri,Sub,undefined)},
      ?MODULE:ws_mode(Sub);
    {'$gen_call',{From,Tag},state} ->
      From ! {Tag, Sub},
      ?MODULE:ws_mode(Sub);
    {'$gen_call',{From,Tag},_Any} ->
      From ! {Tag, unhandled},
      ?MODULE:ws_mode(Sub);
    {state, CPid} ->
      CPid ! {Pid, Sub},
      ?MODULE:ws_mode(Sub);
    stop ->
      Cmd = msgpack:pack(#{null=><<"goodbye">>, <<"r">>=><<"stop">>}),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      Parent ! {wrk_down, self(), stop},
      done;
    {send_msg, Payload} ->
      Cmd = msgpack:pack(Payload),
      gun:ws_send(Pid, {binary, Cmd}),
      ?MODULE:ws_mode(Sub);
    {gun_ws, Pid, _Ref, {binary, Bin}} ->
      {ok,Cmd} = msgpack:unpack(Bin),
      ?LOG_DEBUG("repl client got ~p",[Cmd]),
      Sub1=handle_msg(Cmd, Sub),
      ?MODULE:ws_mode(Sub1);
    {gun_down,Pid,ws,closed,[],[]} ->
      ?LOG_ERROR("Gun down. Giving up...."),
      Parent ! {wrk_down, self(), gundown},
      giveup;
    %{sync_since, Hash, Hei} ->
    %  dosync(Hash,Hei,Sub);
    %runsync ->
    %  #{hash:=BlkHa,header:=#{height:=BlkHe}}=maps:get(last,Sub),
    %  ?LOG_NOTICE("Have to run sync since ~s",[hex:encode(BlkHa)]),
    %  self() ! { sync_since, BlkHa, BlkHe},
    %  ?MODULE:ws_mode(Sub);
    {gun_error, Pid, Reason} ->
      ?LOG_ERROR("Gun error ~p",[Reason]),
      Sub;
    alive ->
      ok=gun:ws_send(Pid, {binary, <<129,192,196,4,"ping">>}),
      erlang:send_after(30000,self(), alive),
      ?MODULE:ws_mode(Sub);
    Any ->
      ?LOG_NOTICE("repl client unknown msg ~p",[Any]),
      ?MODULE:ws_mode(Sub)
  after 5000 ->
          ?LOG_DEBUG("Sending PING"),
          %ok=gun:ws_send(Pid, {binary, msgpack:pack(#{null=><<"ping">>})}),
          ok=gun:ws_send(Pid, {binary, <<129,192,196,4,"ping">>}),
          ?MODULE:ws_mode(Sub)
          %Sub
  end.

handle_msg(#{null := <<"new_block">>,
             <<"block_meta">> := BinBlk,
             <<"hash">> := _Hash,
             <<"stat">> := #{
                     <<"txs">>:=_,
                     <<"settings">>:=_,
                     <<"bals">>:=_
                    },
             <<"now">> := _Now
            }, #{getfun:=F}=Sub) ->
  #{header:=#{parent:=Parent,height:=Height},hash:=Hash}=Block=block:unpack(BinBlk),
  ?LOG_INFO("Got block: ~s",[blkinfo(Block)]),
  %?LOG_INFO("Block ~p",[maps:with([header,temporary,hash],Block)]),
  case maps:is_key(temporary, Block) of
    true ->
      F({apply_block, Block});
    false ->
      gen_server:cast(tpnode_repl,{new_block,{Height,Hash,Parent},maps:get(uri,Sub,undefined)})
  end,
  Sub;

handle_msg(#{null := <<"subscribe_ack">>}, Sub) ->
  Sub;

handle_msg(#{null := <<"banner">>,
             <<"protocol">> := <<"thepower-nodesync-v1">>,
             <<"tpnode-id">> := _NodeId,
             <<"tpnode-name">> := _NodeName
            }, Sub) ->
  %self() ! runsync,
  Sub#{protocol=>v1};

handle_msg(Msg, Sub) ->
  ?LOG_ERROR("Unhandled msg ~p",[Msg]),
  Sub.

presync(#{pid:=Pid,getfun:=F}=Sub, Ptr) ->
      URL= <<"/api/binblock/",Ptr/binary>>,
      ?LOG_INFO("Going to ~s",[URL]),
      case sync_get_decode(Pid,URL) of
        {200, _Headers, #{
                          hash:=Hash,
                          header:=#{parent:=ParentHash,
                                    height:=Hei}
                         }=Blk} ->
          ?LOG_INFO("Has block h=~w 0x~s parent 0x~s",
                     [Hei, hex:encode(Hash), hex:encode(ParentHash)]),
          LBH=maps:get(last,Sub,#{}),
          case Blk of
            #{hash:=BH,header:=_,child:=Child} ->
              T0=erlang:system_time(microsecond),
              Res=if BH==LBH ->
                       ok;
                     true ->
                       F({apply_block, Blk})
                  end,
              T1=erlang:system_time(microsecond),
              ?LOG_INFO("Blk install time ~.f sec~n",[(T1-T0)/1000000]),
              case Res of
                {ok, ignore} ->
                  HexPH=hex:encode(Child),
                  presync(maps:remove(last,Sub), HexPH);
                ok ->
                  HexPH=hex:encode(Child),
                  presync(maps:remove(last,Sub), HexPH);
                Other ->
                  ?LOG_ERROR("presync stop, returned ~p",[Other]),
                  {error, Other}
              end;
            #{hash:=BH,header:=_} ->
              Res=if BH==LBH ->
                       ok;
                     true ->
                       F({apply_block, Blk})
                  end,
              case Res of
                ok ->
                  {ok, maps:remove(last,Sub)};
                {ok, ignore} ->
                  {ok, maps:remove(last,Sub)};
                Other ->
                  ?LOG_ERROR("presync stop, returned ~p",[Other]),
                  {error, Other}
              end
          end;

          %?LOG_INFO("Child ~p",[maps:with([child,children],Blk)]),
          %Stop=if(Hei==0) -> true;
          %       (ParentHash==LastHas) ->
          %         true;
          %       (Hei==LastHei) ->
          %         true;
          %       (Hei<LastHei) ->
          %         true;
          %       true ->
          %         false
          %     end,
          %?LOG_INFO("Stop ~p",[Stop]),
          %if(Stop) ->
          %    {ok, Sub};
          %  true ->
          %    HexPH=hex:encode(ParentHash),
          %    presync(Sub, HexPH)
          %end;
        {500, _Headers, #{<<"ecee">>:=ErrorBody}} ->
          io:format("~s~n",[ErrorBody]),
          ?LOG_ERROR("repl error 500 at ~s: ~s",[URL, ErrorBody]),
          error;
        _Other ->
          ?LOG_INFO("Res ~p",[_Other]),
          ?LOG_ERROR("Giving up",[]),
          error
      end.

%make_ws_req(Pid, Request) ->
%  receive {gun_ws,Pid, {binary, _}} ->
%            throw('unexpected_data')
%  after 0 -> ok
%  end,
%  Cmd = msgpack:pack(Request),
%  ok=gun:ws_send(Pid, {binary, Cmd}),
%  receive {gun_ws,Pid, {binary, Payload}}->
%            {ok, Res} = msgpack:unpack(Payload),
%            Res
%  after 5000 ->
%          throw('ws_timeout')
%  end.

upgrade(Pid) ->
  gun:ws_upgrade(Pid, "/api/ws",
                 [ {<<"sec-websocket-protocol">>, <<"thepower-nodesync-v1">>} ]),
  receive {gun_upgrade,Pid,_Ref,[<<"websocket">>],Headers} ->
            {ok, Headers};
          {gun_response, Pid, _Ref,_Fin,Code,_Hdr} ->
            {error, Code}
  after 10000 ->
          throw(upgrade_timeout)
  end.

sync_get_decode(Pid, Url) ->
  {Code,Header, Body}=sync_get(Pid, Url),
  case proplists:get_value(<<"content-type">>,Header) of
    <<"application/json">> ->
      {Code, Header, jsx:decode(iolist_to_binary(Body), [return_maps])};
    <<"application/msgpack">> ->
      {ok, Res}=msgpack:unpack(iolist_to_binary(Body)),
      {Code, Header, Res};
    <<"binary/tp-block">> ->
      Res=block:unpack(iolist_to_binary(Body)),
      {Code, Header, Res};
    _ ->
      {Code, Header, Body}
  end.

sync_get(Pid, Url) ->
  Ref=gun:get(Pid,Url),
  sync_get_continue(Pid, Ref, {0,[],[]}).

sync_get_continue(Pid, Ref, {PCode,PHdr,PBody}) ->
  {Fin,NS}=receive
             {gun_response,Pid,Ref,IsFin, Code, Headers} ->
               {IsFin, {Code,Headers,PBody} };
             {gun_data,Pid,Ref, IsFin, Payload} ->
               {IsFin, {PCode,PHdr,PBody++[Payload]}}
           after 10000 ->
                   throw(get_timeout)
           end,
  case Fin of
    fin ->
      NS;
    nofin ->
      sync_get_continue(Pid, Ref, NS)
  end.



%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
blkinfo(#{hash:=H,header:=#{height:=Hei,chain:=Ch},temporary:=T}) ->
  io_lib:format("~s h=~w ch=~w tmp=~w",[blockchain:blkid(H),Hei,Ch,T]);
blkinfo(#{hash:=H,header:=#{height:=Hei,chain:=Ch}}) ->
  io_lib:format("~s h=~w ch=~w",[blockchain:blkid(H),Hei,Ch]);
blkinfo(H) ->
  io_lib:format("~s",[blockchain:blkid(H)]).

