-module(txgen).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, process/1, bals/0, is_running/0,
  restart/0, get_wallets/1, bootstrap/1, create_wallets/2, choose_wallets/1,
  start_me/3, stop_all/0, generate_transactions/6]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

is_running() ->
  gen_server:call(?MODULE, status).

restart() ->
  gen_server:call(?MODULE, restart).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  Times = application:get_env(tpnode, txgen_times, 2),
  {ok, #{
    ticktimer=>erlang:send_after(2000, self(), ticktimer),
    counter => Times,
    running => true
  }}.

handle_call(restart, _From, State) ->
  Times = application:get_env(tpnode, txgen_times, 2),
  {reply, restarted, State#{
    ticktimer=>erlang:send_after(100, self(), ticktimer),
    counter => Times,
    running => true
  }};

handle_call(status, _From, #{ticktimer:=_Tmr, running := Running} = State) ->
  {reply, Running, State};

handle_call(_Request, _From, State) ->
  {reply, unknown, State}.

handle_cast(_Msg, State) ->
  lager:info("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(ticktimer,
  #{ticktimer:=Tmr, counter := Counter} = State) ->
  catch erlang:cancel_timer(Tmr),
  TxsCnt = application:get_env(tpnode, txgen_txs, 100),
  Delay = application:get_env(tpnode, txgen_int, 6),
  
  lager:info(
    "Starting TX generator ~w txs with ~w delay ~w more run(s)",
    [TxsCnt, Delay, Counter]
  ),
  
  process(TxsCnt),
  
  if
    Counter > 0 ->
      {noreply, State#{
        ticktimer=>erlang:send_after(Delay * 1000, self(), ticktimer),
        counter => Counter - 1
      }};
    
    true ->
      {noreply, State#{running => false}}
  end;


handle_info(_Info, State) ->
  lager:info("Unknown info ~p", [_Info]),
  {noreply, State}.


terminate(_Reason, _State) ->
  ok.


code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

bals() ->
  {ok, [L]} = file:consult("txgen.txt"),
  RS = lists:foldl(fun({Addr, _PKey}, Acc) ->
    Ledger = ledger:get(Addr),
    Bal = bal:get_cur(<<"SK">>, Ledger),
    [Bal | Acc]
                   end, [], L),
  {median(lists:sort(RS)), lists:sum(RS) / length(RS), lists:sum(RS), length(RS)}.

%% -------------------------------------------------------------------------------------

process(N) ->
  {ok, [L]} = file:consult("txgen.txt"),
  Addrs = lists:map(fun({Addr, _PKey}) -> Addr end, L),
  AL = length(Addrs),
  Prop = N / (AL * (AL - 1)),
  PickAddr =
    fun(Addr0) ->
      lists:map(
        fun({_, A}) -> A end,
        lists:sort(
          lists:filtermap(
            fun
              (A0) when A0 == Addr0 ->
                false;
              (A0) ->
                {true, {rand:uniform(), A0}}
            end,
            Addrs
          )
        )
      )
    end,
  L1 = lists:foldl(
    fun({Addr, _PKey}, Acc) ->
      Ledger = ledger:get(Addr),
      Bal = bal:get_cur(<<"SK">>, Ledger),
      Seq0 = bal:get(seq, Ledger),
      
      if
        (Bal == 0) ->
          Acc;
        
        true ->
          ToList = PickAddr(Addr),
          TS = Bal / length(ToList),
          
          {_, TR} = lists:foldl(
            fun(To, {Seq, Acc1}) ->
              R0 = rand:uniform(),
              Amount = round((rand:uniform(100) / 100) * TS),
              
              if (Amount > 0 andalso R0 < Prop) ->
                Tx = #{
                  amount=>Amount,
                  cur=><<"SK">>,
                  extradata=>jsx:encode(#{}),
                  from=>Addr,
                  to=>To,
                  seq=>Seq + 1,
                  timestamp=>os:system_time(millisecond)
                },
                STX = tx:sign(Tx, _PKey),
                {Seq + 1, Acc1 ++ [
                  {{naddress:encode(Addr),
                    naddress:encode(To),
                    Amount},
                    STX
                  }]};
                true ->
                  {Seq, Acc1}
              end
            end, {Seq0, []}, ToList),
          Acc ++ TR
      end
    end, [], L),
  lists:map(
    fun({T1, _TX}) ->
      case txpool:new_tx(_TX) of
        {ok, TXID} ->
          {T1, TXID};
        _ ->
          {T1, error}
      end
    end,
    L1
  ).

%% -------------------------------------------------------------------------------------

write_terms(Filename, List) when is_list(List) ->
  file:write_file(
    Filename,
    lists:map(
      fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
      List
    ),
    [append]
  ).

%% -------------------------------------------------------------------------------------

tx_register_new_address(Pvt) ->
  Pub = tpecdsa:calc_pub(Pvt, true),
  Transaction = #{
    kind => register,
    t => os:system_time(millisecond),
    ver => 2,
    keys => [Pub]
  },
  tx:sign(tx:construct_tx(Transaction, [{pow_diff, 8}]), Pvt).


%% -------------------------------------------------------------------------------------


get_tx_status(TxId, BaseUrl) ->
  get_tx_status(TxId, BaseUrl, 60).

get_tx_status(_TxId, _BaseUrl, 0 = _Trys) ->
  {ok, timeout, _Trys};

get_tx_status(TxId, BaseUrl, Try) ->
  Res = make_http_request(
    get,
    make_list(BaseUrl) ++ "/api/tx/status/" ++ make_list(TxId)
  ),
  Status = maps:get(<<"res">>, Res, null),

  case Status of
    null ->
      timer:sleep(1000),
      get_tx_status(TxId, BaseUrl, Try - 1);
    AnyValidStatus ->
      {ok, AnyValidStatus, Try}
  end.


api_get_tx_status(TxId, BaseUrl) ->
  Status = get_tx_status(TxId, BaseUrl),
  case Status of
    {ok, timeout, _} ->
      io:format("got transaction ~p timeout~n", [TxId]);
    {ok, #{<<"res">> := <<"bad_seq">>}, _} ->
      io:format("got transaction ~p badseq~n", [TxId]);
    _ ->
      ok
  end,
  Status.


%% -------------------------------------------------------------------------------------


create_wallets(_Chain, 0, Acc) ->
  Acc;

create_wallets(Chain, WalletsCount, Acc) when is_integer(WalletsCount), is_integer(Chain) ->
  Pvt = tpecdsa:generate_priv(),
  Tx = tx_register_new_address(Pvt),
  BaseUrl = bootstrap(Chain),
  Res = post_tx(BaseUrl, Tx),
  io:format("register result: ~p~n", [Res]),
  TxId = maps:get(<<"txid">>, Res, unknown),
  Status = api_get_tx_status(TxId, BaseUrl),
  io:format("transaction status: ~p~n", [Status]),
  {ok, #{<<"ok">> := true, <<"res">> := WalletAddress}, _} = Status,
  write_terms(
    "wallets-" ++ integer_to_list(Chain) ++ ".txt",
    [{WalletAddress, Pvt}]
  ),
  create_wallets(Chain, WalletsCount - 1, Acc ++ [{WalletAddress, Pvt}]).



%% -------------------------------------------------------------------------------------

get_chain_wallets(4) ->
  10;
get_chain_wallets(5) ->
  10;
get_chain_wallets(6) ->
  10;

get_chain_wallets(_) ->
  101.

create_wallets(Chain, WalletsCount) when is_integer(WalletsCount), is_integer(Chain) ->
  io:format("Creating ~p new wallets for chain ~p~n", [WalletsCount, Chain]),
  create_wallets(Chain, WalletsCount, []).
  

get_wallets(Chain) when is_integer(Chain)->
  FileName = "wallets-" ++ integer_to_list(Chain) ++ ".txt",
  ChainWalletsCount = get_chain_wallets(Chain),
  
  % format: [ {WalletAddress, PvtKey}, ... ]
  Wallets =
    case file:consult(FileName) of
      {ok, WalletsFromFile} when is_list(WalletsFromFile) ->
        WalletsLength = length(WalletsFromFile),
        io:format("Read ~p wallets from file~n", [WalletsLength]),
        case WalletsLength of
          WalletsLength1 when (WalletsLength1 < ChainWalletsCount) ->
            NewWallets1 =
              WalletsFromFile ++ create_wallets(Chain, ChainWalletsCount - WalletsLength1),
%%            write_terms(FileName, NewWallets1),
            NewWallets1;
          _ ->
            WalletsFromFile
        end;
      Err1 ->
        io:format("Can't read wallets from file: ~p ~p~n", [FileName, Err1]),
        NewWallets = create_wallets(Chain, ChainWalletsCount),
%%        write_terms(FileName, NewWallets),
        io:format("wallets: ~p~n", [NewWallets]),
        NewWallets
    end,
  Wallets.

%% -------------------------------------------------------------------------------------

bootstrap(Chain) when is_integer(Chain), Chain>=4, Chain=<6 ->
  Host = "pwr.local",
  FirstPort = list_to_integer("498" ++ integer_to_list(Chain) ++ "1"),
  Port = rand:uniform(3)-1+FirstPort,
  "http://" ++ Host ++ ":" ++ integer_to_list(Port);

bootstrap(Chain) when is_integer(Chain), Chain>=10, Chain=<69  ->
  rand:seed(exs1024s, os:timestamp()),
  AllPorts = [{10, 43290}, {11, 43291}, {12, 43292}, {13, 43293}, {14, 43294}, {15, 43295}, {16, 43296}, {17, 43297}, {18, 43298}, {19, 43299}, {20, 43300}, {21, 43301}, {22, 43302}, {23, 43303}, {24, 43304}, {25, 43305}, {26, 43306}, {27, 43307}, {28, 43308}, {29, 43309}, {30, 43310}, {31, 43371}, {32, 43312}, {33, 43313}, {34, 43314}, {35, 43315}, {36, 43316}, {37, 43317}, {38, 43318}, {39, 43319}, {40, 43320}, {41, 43321}, {42, 43322}, {43, 43323}, {44, 43324}, {45, 43325}, {46, 43326}, {47, 43327}, {48, 43328}, {49, 43329}, {50, 43330}, {51, 43331}, {52, 43332}, {53, 43333}, {54, 43334}, {55, 43335}, {56, 43336}, {57, 43337}, {58, 43338}, {59, 43339}, {60, 43340}, {61, 43341}, {62, 43342}, {63, 43343}, {64, 43344}, {65, 43345}, {66, 43346}, {67, 43347}, {68, 43348}, {69, 43349}],
  FirstNode = (Chain-10)*3,
%%  Node = rand:uniform(3)-1+FirstNode,
  Node = FirstNode,
  Region =
    case Node>35 of
      true ->
        "northeurope";
      _ ->
        "westeurope"
    end,
  Port = proplists:get_value(Chain, AllPorts),
  "http://powernode" ++ integer_to_list(Node) ++ "." ++
    Region ++ ".cloudapp.azure.com:" ++ integer_to_list(Port).
  

%%bootstrap(Chain) ->
%%  Url = "http://powernode25.westeurope.cloudapp.azure.com:43298/api/nodes/" ++ integer_to_list(Chain),
%%  {ok, {Code, _, Res}} =
%%    httpc:request(get, {Url, []}, [], [{body_format, binary}]),
%%
%%  case Code of
%%    {_, 200, _} ->
%%      X = jsx:decode(Res, [return_maps]),
%%      CN = maps:get(<<"chain_nodes">>, X),
%%      Addr =
%%        case maps:keys(CN) of
%%          [] ->
%%            throw(no_address);
%%          Addrs ->
%%            hd(Addrs)
%%        end,
%%      binary_to_list(hd(lists:filter(
%%        fun
%%          (<<"http://", _/binary>>) -> true;
%%          (_) -> false
%%        end, settings:get([Addr, <<"ip">>], CN)
%%      )));
%%    true ->
%%      {error, Code}
%%  end.

%% -------------------------------------------------------------------------------------


post_tx(Base, Tx) when is_map(Tx) ->
  {ok, {_Code, _, Res}} =
    httpc:request(post,
      { Base ++ "/api/tx/new.bin",
        [],
        "binary/octet-stream",
        tx:pack(Tx)
      },
      [], [{body_format, binary}]),
  io:format("~s~n", [Res]),
  process_http_answer(Res).



%% -------------------------------------------------------------------------------------


median([]) -> 0;
median([E]) -> E;
median(List) ->
  LL = length(List),
  DropL = (LL div 2) - 1,
  {_, [M1, M2 | _]} = lists:split(DropL, List),
  case LL rem 2 of
    0 -> %even elements
      (M1 + M2) / 2;
    1 -> %odd
      M2
  end.

%% -------------------------------------------------------------------------------------

make_list(Arg) when is_list(Arg) ->
  Arg;

make_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg);

make_list(_Arg) ->
  throw(badarg).

%% -------------------------------------------------------------------------------------

%%make_http_request(post, Url, Params) when is_list(Url) andalso is_map(Params) ->
%%  RequestBody = jsx:encode(Params),
%%  Query = {Url, [], "application/json", RequestBody},
%%  {ok, {{_, 200, _}, _, ResponceBody}} =
%%    httpc:request(post, Query, [], [{body_format, binary}]),
%%  process_http_answer(ResponceBody).

make_http_request(get, Url) when is_list(Url) ->
  Query = {Url, []},
  {ok, {{_, 200, _}, _, ResponceBody}} =
    httpc:request(get, Query, [], [{body_format, binary}]),
  process_http_answer(ResponceBody).

process_http_answer(AnswerBody) ->
  Answer = jsx:decode(AnswerBody, [return_maps]),
  check_for_success(Answer),
  Answer.

check_for_success(Data) when is_map(Data) ->
  % answers without ok are temporary assumed successfully completed
  Success = maps:get(<<"ok">>, Data, true),
  if
    Success =/= true ->
      Code = maps:get(<<"code">>, Data, 0),
      Msg = maps:get(<<"msg">>, Data, <<"">>),
      throw({apierror, Code, Msg});
    true ->
      ok
  end.

%% -------------------------------------------------------------------------------------
address_converter({Addr, Pvt}) ->
  {naddress:decode(Addr), Pvt};

address_converter([{Addr, Pvt}]) ->
  [address_converter({Addr, Pvt})];

address_converter([AddrTerm | Rest]) ->
  [address_converter(AddrTerm)] ++ address_converter(Rest).

%% -------------------------------------------------------------------------------------

uniq_seq_generator(Count, ListLength) when (Count < ListLength) ->
  uniq_seq_generator(Count, ListLength, []).

uniq_seq_generator(0, _ListLength, Seq) ->
  Seq;

uniq_seq_generator(Count, ListLength, Seq) ->
  Element = rand:uniform(ListLength),
  case lists:member(Element, Seq) of
    true ->
      uniq_seq_generator(Count, ListLength, Seq); % need another element
    _ ->
      uniq_seq_generator(Count-1, ListLength, Seq ++ [Element])
  end.
  
%% -------------------------------------------------------------------------------------

choose_wallets(AllWallets) ->
  From = lists:nth(rand:uniform(length(AllWallets)), AllWallets),
  To = AllWallets -- [From],
  [address_converter(From), address_converter(To)].

%% -------------------------------------------------------------------------------------

choose_wallets2(AllWallets, Processes) ->
  SenderNoList = uniq_seq_generator(Processes, length(AllWallets)),
  AllWalletsBin = address_converter(AllWallets),
  lists:map(
    fun(SenderNo) ->
      From = lists:nth(SenderNo, AllWalletsBin),
      To = AllWalletsBin -- [From],
      [From, To]
    end,
    SenderNoList
  ).

%% -------------------------------------------------------------------------------------

parse_http_addr(Addr) when is_list(Addr) ->
  {ok, {_, _, ParsedAddr, ParsedPort, _, _}} = http_uri:parse(Addr),
  {ParsedAddr, ParsedPort}.

%% -------------------------------------------------------------------------------------


generate_transactions(Chain, TransCount, [From, ToList], StartTime, WorkerId, Owner) when is_pid(Owner) ->
%%  [_ | Wallets] = get_wallets(Chain),
%%  [From, ToList] = choose_wallets(Wallets),
  Base = bootstrap(Chain),
  io:format("worker ~p send trs to ~p ~n", [WorkerId, Base]),
  {BaseIp, BasePort} = parse_http_addr(Base),
  {ok, ConnPid} = gun:open(BaseIp, BasePort),
  Options = {Owner, Base, ConnPid, StartTime, TransCount, WorkerId},
  generate_transactions(From, ToList, Options, TransCount),
  gun:close(ConnPid).


generate_transactions(_From, _ToList, _Options, 0) ->
  ok;

generate_transactions(
    {From, FromPvt},
    ToList,
    {_Owner, _Base, ConnPid, StartTime, StartCount, WorkerId} = Options,
    TransCount) ->
  
  check_stop_flag(),
  
  case TransCount =/= StartCount andalso TransCount rem 50 =:= 0 of
    true ->
      TimeDiff = os:system_time(millisecond) - StartTime,
      Tps =
        case TimeDiff of
          0 ->
            0;
          TimeDiff2 ->
            (StartCount - TransCount) * 1000 / TimeDiff2
        end,
%%      io:format("-> ~p ~p ~p ~p ~n", [StartCount, TransCount, StartTime, Tps]),
  
      _Owner ! {reply, WorkerId, TransCount, Tps, self()};
    
    _ ->
      pass
  end,
  
  {To, _} = lists:nth(rand:uniform(length(ToList)), ToList),
%%  io:format("~p -> ~p ~n", [From, To]),
  Tx = tx_money_transfer(From, To, FromPvt),

%%  post_tx(Base, Tx),
  
%%  try
    StreamRef =
      gun:post(
        ConnPid,
        "/api/tx/new.bin",
        [ {<<"content-type">>, <<"binary/octet-stream">>} ],
        tx:pack(Tx)
      ),
  
    _Answer =
      case gun:await(ConnPid, StreamRef) of
        {response, fin, _Status, _Headers} ->
          no_data;
        {response, nofin, _Status, _Headers} ->
          {ok, Body} = gun:await_body(ConnPid, StreamRef),
          Body;
        {error, timeout} ->
          io:format("timeout~n"),
          no_data
      end,
%%  io:format("answer: ~s~n", [_Answer]),
  
%%  catch
%%      Ec:Ee  ->
%%        io:format("crash: ~p:~p~n", [Ec, Ee])
%%  end,
  generate_transactions({From, FromPvt}, ToList, Options, TransCount-1).

%% -------------------------------------------------------------------------------------

check_stop_flag() ->
  case application:get_env(tpnode, generator) of
    stop ->
      throw(force_stop);
    _ ->
      pass
  end.



%% -------------------------------------------------------------------------------------
tx_money_transfer(From, To, Pvt) ->
  Amount = rand:uniform(10)+1,
  FeeCur = Cur = <<"SK">>,
  
  T1 = #{
    kind => generic,
    t => os:system_time(millisecond),
    seq => os:system_time(microsecond),
    from => From,
    to => To,
    ver => 2,
    txext => #{},
    payload => [
      #{amount => Amount, cur => Cur, purpose => transfer},
      #{amount => 200, cur => FeeCur, purpose => srcfee}
    ]
  },
  tx:sign(tx:construct_tx(T1),Pvt).



%% -------------------------------------------------------------------------------------
stop_all() ->
  application:set_env(tpnode, generator, stop).


%% -------------------------------------------------------------------------------------

start_me(Chain, TransactionsPerProcess, Processes) ->
  application:ensure_all_started(inets),
  application:set_env(tpnode, generator, start),
  rand:seed(exs1024s, os:timestamp()),
  [_ | Wallets] = get_wallets(Chain),
  WalletsList = choose_wallets2(Wallets, Processes),
  
  Starter =
    fun(Addresses, WorkerId) ->
      erlang:spawn(?MODULE, generate_transactions,
        [Chain, TransactionsPerProcess, Addresses,
          os:system_time(millisecond), WorkerId, self()])
    end,
  {_, Pids} =
    lists:foldl(
      fun(Addr, {WorkerId, PidsList}) ->
        {WorkerId+1, PidsList ++ [Starter(Addr, WorkerId)]}
      end,
      {0, []},
      WalletsList
    ),
  wait_for_reply(TransactionsPerProcess, #{}, Pids).


wait_for_reply(TransactionsPerProcess, TpsMap, Pids) ->
  receive
    {reply, WorkerId, _TransCount, Tps, SenderPid} ->
      TpsMap2 = maps:put(SenderPid, Tps, TpsMap),
      TpsTotal = lists:sum(maps:values(TpsMap2)),
      io:format("tps [~p]: ~p, total: ~p~n", [WorkerId, Tps, TpsTotal]),
      wait_for_reply(TransactionsPerProcess, TpsMap2, Pids)
%%      wait_for_reply(TransactionsPerProcess, TpsMap2, [TransactionsPerProcess - _TransCount | List])
  after 1000 ->
    check_stop_flag(),
    Alive = [is_process_alive(Pid) || Pid <- Pids],
    % set proccess tps to zero if where exists finished workers
    TpsMap2 =
      case lists:member(false, Alive) of
        true ->
          maps:map(
            fun(WorkerPid, Val) ->
              case is_process_alive(WorkerPid) of
                true ->
                  Val;
                _ ->
                  0
              end
            end,
            TpsMap
          );
        _ ->
          TpsMap
      end,
    % continue waiting if live workers are exists
    case lists:member(true, Alive) of
      true ->
        io:format("still alive ~p~n", [Alive]),
        wait_for_reply(TransactionsPerProcess, TpsMap2, Pids);
      _ ->
        ok
    end
  end.
  
