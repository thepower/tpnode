%%%-------------------------------------------------------------------
%% @doc tpnode_repl_worker
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_repl_worker).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2022-07-12").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,run/2,ws_mode/1,genesis/1]).
-export([run/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

run() ->
  tpnode_repl_worker:run(
    #{
      parent=>self(),
      protocol=>http,
      address=>"127.0.0.1",
      port=>49841
     },
    fun(chain)->104;
       (last_known_block) -> blockchain:last_meta();
       (Any) -> io:format("requested ~p~n",[Any]),
                ok 
    end).

start_link(Sub0) ->
  GetFun=fun(node_id) ->
             nodekey:node_id();
            (chain) ->
             blockchain:chain();
            ({apply_block,#{hash:=_H}=Block}) ->
             txpool:inbound_block(Block);
            ({last,ChainNo}) ->
             Last=chainsettings:by_path([
                                         <<"current">>,
                                         <<"sync_status">>,
                                         msgpack:pack(ChainNo),
                                         <<"block">>]),
             lager:info("Last known to ch ~b: ~p",[ChainNo,Last]),
             Last
         end,
  Sub=case Sub0 of
        _ when is_list(Sub0) ->
          #{ uri => Sub0 };
        #{protocol:=_,address:=_,port:=_} ->
          Sub0
      end,
  Pid=spawn(?MODULE,run,[Sub#{parent=>self()}, GetFun]),
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
  lager:error("replica protocol ~p does not supported",[Proto]),
  Parent ! {wrk_down, self(), {error,badproto}},
  throw(badproto).


run(#{parent:=Parent, protocol:=_Proto, address:=Ip, port:=Port} = Sub, GetFun) ->
    lager:info("repl client connecting to ~p ~p", [Ip, Port]),
    Pid=connect(Sub),
        try
    Genesis=case sync_get_decode(Pid, "/api/binblock/genesis") of
            {200, _, V1} when is_map(V1) -> V1;
            {404, _, _} -> throw('incompatible');
            _ -> throw('incompatible')
          end,
    case blockchain:rel(genesis,self) of
      #{hash:=Hash} ->
        case maps:get(hash, Genesis) == Hash of
          false ->
            file:write_file("genesis_repl.txt",
                            io_lib:format("~p.~n",[Genesis])),
            lager:notice("Genesis mismatch for replication. Their genesis saved in genesis_repl.txt"),
            throw('genesis_mismatch');
          true ->
            lager:info("Genesis ok")
        end;
      _ ->
        throw('unexpected_genesis')
    end,
    LastBlock=case sync_get_decode(Pid, "/api/binblock/last") of
            {200, _, V2} -> maps:with([hash,header],V2);
            _ -> throw('cant_get_last')
          end,
    lager:info("Their lastblk: ~p",[LastBlock]),

    KnownBlock=GetFun(last_known_block),
    lager:info("My lastblk: ~p",[KnownBlock]),
    {ok,Sub1}=presync(Sub#{pid=>Pid,getfun=>GetFun,
                           last=>maps:with([hash,header],KnownBlock)},
                      hex:encode(maps:get(hash,KnownBlock))),

    {ok,UpgradeHdrs}=upgrade(Pid,undefined),
    lager:info("Conn upgrade hdrs: ~p",[UpgradeHdrs]),

    MyChain=GetFun(chain),
    Cmd = msgpack:pack(#{ null=><<"subscribe">>, <<"channel">> => MyChain}),
    ok=gun:ws_send(Pid, {binary, Cmd}),

    Parent ! {wrk_up, self(), undefined},
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
          %S=erlang:get_stacktrace(),
          lager:error("repl client error ~p:~p",[Ec,Ee]),
          lists:foreach(
            fun(SE) ->
                lager:error("@ ~p", [SE])
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
      lager:error("Linked process went down ~p. Giving up....",[Reason]),
      Cmd = msgpack:pack(#{null=><<"goodbye">>, <<"r">>=><<"deadparent">>}),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      exit;
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
    {gun_ws, Pid, {binary, Bin}} ->
      {ok,Cmd} = msgpack:unpack(Bin),
      lager:debug("XChain client got ~p",[Cmd]),
      Sub1=handle_msg(Cmd, Sub),
      ?MODULE:ws_mode(Sub1);
    {gun_down,Pid,ws,closed,[],[]} ->
      lager:error("Gun down. Giving up...."),
      Parent ! {wrk_down, self(), gundown},
      giveup;
    %{sync_since, Hash, Hei} ->
    %  dosync(Hash,Hei,Sub);
    %runsync ->
    %  #{hash:=BlkHa,header:=#{height:=BlkHe}}=maps:get(last,Sub),
    %  lager:notice("Have to run sync since ~s",[hex:encode(BlkHa)]),
    %  self() ! { sync_since, BlkHa, BlkHe},
    %  ?MODULE:ws_mode(Sub);
    {gun_error, Pid, Reason} ->
      logger:error("Gun error ~p",[Reason]),
      Sub;
    Any ->
      lager:notice("XChain client unknown msg ~p",[Any]),
      ?MODULE:ws_mode(Sub)
  after 5000 ->
          ok=gun:ws_send(Pid, {binary, msgpack:pack(#{null=><<"ping">>})}),
          %?MODULE:ws_mode(Sub)
          Sub
  end.

%dosync(Hash, _Height, #{pid:=Pid}=Sub) ->
%  Hex=hex:encode(Hash),
%  R=sync_get(Pid, <<"/api/binblock/",Hex/binary>>),
%  io:format("R ~p~n",[R]),
%  Sub.


handle_msg(#{null := <<"banner">>,
             <<"protocol">> := <<"thepower-nodesync-v1">>,
             <<"tpnode-id">> := _NodeId,
             <<"tpnode-name">> := _NodeName
            }, Sub) ->
  %self() ! runsync,
  Sub#{protocol=>v1};

handle_msg(Msg, Sub) ->
  lager:error("Unhandled msg ~p",[Msg]),
  Sub.

presync(#{pid:=Pid, parent:=Parent}=Sub, Ptr) ->
      Parent ! {wrk_presync, self(), start},
      URL= <<"/api/binblock/",Ptr/binary>>,
      lager:info("Going to ~s",[URL]),
      case sync_get_decode(Pid,URL) of
        {200, _Headers, #{
                          hash:=Hash,
                          header:=#{parent:=ParentHash,
                                    height:=Hei}
                         }=Blk} ->
          lager:info("Has block h=~w 0x~s parent 0x~s",
                     [Hei, hex:encode(Hash), hex:encode(ParentHash)]),
          case Blk of
            #{child:=Child} ->
              HexPH=hex:encode(Child),
              presync(Sub, HexPH);
            #{} ->
              {ok, Sub}
          end;

          %lager:info("Child ~p",[maps:with([child,children],Blk)]),
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
          %lager:info("Stop ~p",[Stop]),
          %if(Stop) ->
          %    {ok, Sub};
          %  true ->
          %    HexPH=hex:encode(ParentHash),
          %    presync(Sub, HexPH)
          %end;
        {500, _Headers, #{<<"ecee">>:=ErrorBody}} ->
          io:format("~s~n",[ErrorBody]),
          lager:error("repl error 500 at ~s: ~s",[URL, ErrorBody]),
          error;
        _Other ->
          lager:info("Res ~p",[_Other]),
          lager:error("Giving up",[]),
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

upgrade(Pid, _) ->
  gun:ws_upgrade(Pid, "/api/ws",
                 [ {<<"sec-websocket-protocol">>, <<"thepower-nodesync-v1">>} ]),
  receive {gun_ws_upgrade,Pid,Status,Headers} ->
            {Status, Headers};
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

