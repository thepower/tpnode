-module(blockchain_netmgmt).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2022-11-11").

-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2]).
-export([new_block/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Service,Options) ->
  ?LOG_NOTICE("Start service ~w",[Service]),
  gen_server:start_link({local, Service}, ?MODULE, [Service, Options], []).

new_block(Service,Blk) ->
  gen_server:call(Service, {new_block, Blk}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([ServiceName, #{}=Args]) when is_atom(ServiceName) ->
  Table=ets:new(ServiceName,[named_table,protected,set,{read_concurrency,true}]),
  ?LOG_INFO("Table created: ~p",[Table]),
  {ok, LDB}=ldb:open(utils:dbpath(ServiceName)),
  LastBlockHash=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),

  %Conf=load_sets(LDB, LastBlock),
  ?LOG_INFO("My last block hash ~s", [bin2hex:dbin2hex(LastBlockHash)]),
  Res=Args#{
        ldb=>LDB,
        %settings=>chainsettings:settings_to_ets(Conf),
        lastblockhash=>LastBlockHash
       },
  erlang:send_after(6000, self(), runsync),
  {ok, Res}.

handle_call(get_dbh, _From, #{ldb:=LDB}=State) ->
  {reply, {ok, LDB}, State};


%% first block
handle_call({new_block, #{hash:=BlockHash,
                          header:=#{height:=0, chain:=Chain}=_Header}=Blk},
            _From,
            #{ldb:=LDB, genesis:=GenesisHash }=State) ->
  if BlockHash=/=GenesisHash ->
       {reply, {error, bad_genesis}, State};
     true ->
       Conf=load_sets(LDB, Blk),

       {reply, ok, State#{
                     lastblock=>Blk,
                     settings=>chainsettings:settings_to_ets(Conf),
                     mychain=>Chain
                    }}
  end;

%% next blocks
handle_call({new_block, #{hash:=BlockHash,
                          header:=#{chain:=Chain,height:=Hei}=Header}=Blk},
            _From,
            #{ldb:=LDB,
              settings:=Sets,
              lastblock:=#{header:=#{}, hash:=LBlockHash}=LastBlock,
              mychain:=MyChain
             }=State) ->
  ?LOG_INFO("Arrived netmgmt block Verify block with ~p",
             [maps:keys(Blk)]),

  ?LOG_INFO("New netmgmt block (~p/~p) hash ~s (~s)",
             [
              Hei,
              maps:get(height, maps:get(header, LastBlock)),
              blkid(BlockHash),
              blkid(LBlockHash)
             ]),
  try
    if(MyChain =/= Chain) ->
        throw('wrong_chain');
      true ->
        ok
    end,
    case block:verify(Blk) of
      false ->
        file:write_file("tmp/bad_netmgmtblock_" ++
                        integer_to_list(maps:get(height, Header)) ++ ".txt",
                        io_lib:format("~p.~n", [Blk])
                       ),
        ?LOG_INFO("Got bad netmgmt block New block ~w arrived ~s",
                   [Hei, blkid(BlockHash)]),
        throw(bad_block);
      {true, {Success, _}} ->
        LenSucc=length(Success),
        if LenSucc>0 ->
             ?LOG_INFO("New netmgmt block ~w arrived ~s, verify ~w sig",
                        [Hei, blkid(BlockHash), length(Success)]),
             ok;
           true ->
             ?LOG_INFO("New netmgmt block ~w arrived ~s, no valid sig",
                        [Hei, blkid(BlockHash)]),
             throw(ingore)
        end,
        ?LOG_DEBUG("netmgmt sig ~p", [Success]),
        MinSig=getset(minsig,State),
        if LenSucc<MinSig ->
             throw(minsig);
           true -> ok
        end,

        %enough signs. Make block.
        NewPHash=maps:get(parent, Header),

        if LBlockHash==BlockHash ->
             ?LOG_INFO("Ignore repeated block ~s",
                       [
                        blkid(LBlockHash)
                       ]),
             throw(ignore);
           true ->
             ok
        end,
        if LBlockHash=/=NewPHash ->
             ?LOG_NOTICE("Netmgmt got block with wrong parent, height ~p/~p new block parent ~s, but my ~s",
                         [
                          maps:get(height, maps:get(header, Blk)),
                          maps:get(height, maps:get(header, LastBlock)),
                          blkid(NewPHash),
                          blkid(LBlockHash)
                         ]),
             throw({error,need_sync});
           true ->
             ok
        end,
        %normal block installation

        %NewTable=apply_bals(MBlk, Tbl),
        Sets1_pre=apply_block_conf(Blk, Sets),
        Sets1=apply_block_conf_meta(Blk, Sets1_pre),

        NewLastBlock=LastBlock#{
                       child=>BlockHash
                      },

        save_block(LDB, NewLastBlock, false),
        save_block(LDB, Blk, true),

        save_sets(LDB, Blk, Sets, Sets1),

        %Settings=maps:get(settings, MBlk, []),

        ?LOG_INFO("netmgmt enough confirmations ~w/~w. Installing new block ~s h= ~b",
                  [
                   LenSucc, MinSig,
                   blkid(BlockHash),
                   Hei
                  ]),

        {reply, ok, State#{
                      prevblock=> NewLastBlock,
                      lastblock=> Blk,
                      pre_settings => Sets,
                      settings=>if Sets==Sets1 ->
                                     Sets;
                                   true ->
                                     chainsettings:settings_to_ets(Sets1)
                                end
                     }
        }
    end
  catch throw:ignore ->
          {reply, {ok, ignore}, State};
        throw:{error, Descr} ->
          {reply, {error, Descr}, State};
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_ERROR("BC new_block error ~p:~p", [Ec, Ee]),
          lists:foreach(
            fun(Se) ->
                ?LOG_ERROR("at ~p", [Se])
            end, S),
          {reply, {error, unknown}, State}
  end;

handle_call(_Request, _From, State) ->
  ?LOG_INFO("Unhandled ~p",[_Request]),
  {reply, unhandled_call, State}.

handle_cast(_Msg, State) ->
  ?LOG_INFO("Unknown cast ~p", [_Msg]),
  file:write_file("tmp/unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
  file:write_file("tmp/unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
  {noreply, State}.

handle_info(_Info, State) ->
  ?LOG_INFO("BC unhandled info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ?LOG_ERROR("Terminate blockchain ~p", [_Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

format_status(_Opt, [_PDict, State]) ->
  State#{
    ldb=>handler
   }.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
save_sets(ignore, _Blk, _OldSettings, _Settings) -> ok;

save_sets(LDB, #{hash:=Hash, header:=#{parent:=Parent}}, OldSettings, Settings) ->
  ldb:put_key(LDB, <<"settings:",Parent/binary>>, erlang:term_to_binary(OldSettings)),
  ldb:put_key(LDB, <<"settings:",Hash/binary>>, erlang:term_to_binary(Settings)),
  ldb:put_key(LDB, <<"settings">>, erlang:term_to_binary(Settings)).

save_block(ignore, _Block, _IsLast) -> ok;
save_block(LDB, #{hash:=BlockHash,header:=#{height:=Hei}}=Block, IsLast) ->
  ldb:put_key(LDB, <<"block:", BlockHash/binary>>, Block),
  ldb:put_key(LDB, <<"h:", Hei:64/big>>, BlockHash),
  if IsLast ->
       ldb:put_key(LDB, <<"lastblock">>, BlockHash);
     true ->
       ok
  end.

load_sets(LDB, LastBlock) ->
  case ldb:read_key(LDB, <<"settings">>, undefined) of
    undefined ->
      apply_block_conf(LastBlock, settings:new());
    Bin ->
      binary_to_term(Bin)
  end.

apply_block_conf_meta(#{hash:=Hash}=Block, Conf0) ->
  Meta=#{ublk=>Hash},
  S=maps:get(settings, Block, []),
  lists:foldl(
    fun({_TxID, #{patch:=Body}}, Acc) -> %old patch
        settings:patch(settings:make_meta(Body,Meta), Acc);
       ({_TxID, #{patches:=Body,kind:=patch}}, Acc) -> %new patch
        settings:patch(settings:make_meta(Body,Meta), Acc)
    end, Conf0, S).

apply_block_conf(Block, Conf0) ->
  S=maps:get(settings, Block, []),
  if S==[] -> ok;
     true ->
       file:write_file("tmp/applyconf.txt",
                       io_lib:format("APPLY BLOCK CONF ~n~p.~n~n~p.~n~p.~n",
                                     [Block, S, Conf0])
                      )
  end,
  lists:foldl(
    fun({_TxID, #{patch:=Body}}, Acc) -> %old patch
        ?LOG_NOTICE("TODO: Must check sigs"),
        %Hash=crypto:hash(sha256, Body),
        settings:patch(Body, Acc);
       ({_TxID, #{patches:=Body,kind:=patch}}, Acc) -> %new patch
        ?LOG_NOTICE("TODO: Must check sigs"),
        %Hash=crypto:hash(sha256, Body),
        settings:patch(Body, Acc)
    end, Conf0, S).

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).

getset(Name,#{settings:=Sets, mychain:=MyChain}=_State) ->
  chainsettings:get(Name, Sets, fun()->MyChain end).

