-module(erun_querier).
-export([q/5]).

q(Node, Address, Function, Params, Gas) ->
  #{scheme:=Sch,
    host:=Host,
    port:=Port} = uri_string:parse(Node),
  %http://195.3.252.69:49841/api/address/0x8001400004000008/code
  Opts=case Sch of
         "https" -> #{ transport=>tls };
         "http" ->  #{ transport=>tcp }
       end,
  {ok, ConnPid} = gun:open(Host,Port,Opts),
  {ok, _} = gun:await_up(ConnPid),
  Get=fun(Endpoint) ->
          StreamRef = gun:get(ConnPid, Endpoint, []),
          {response, Fin, Code, _Headers} = gun:await(ConnPid, StreamRef),
          Body=case Fin of
                 fin -> <<>>;
                 nofin ->
                   {ok, Body2} = gun:await_body(ConnPid, StreamRef),
                   Body2
               end,
          {Code, Body}
      end,

  {200, Bytecode} = Get(<<"/api/address/0x",(hex:encode(Address))/binary,"/code">>),
  %Bytecode = eevm_asm:assemble(<<"push 0
  %sload
  %push 0
  %mstore
  %calldatasize
  %push 0
  %push 32
  %calldatacopy
  %push 24
  %calldatasize
  %push 32
  %add
  %sub
  %push 24
  %return">>),
  SLoad=fun(Addr, IKey, _Ex0) ->
            {200,St1}=Get(<<"/api/address/0x",(hex:encode(binary:encode_unsigned(Addr)))/binary,
                            "/state/0x",(hex:encode(binary:encode_unsigned(IKey)))/binary>>),
            Res=binary:decode_unsigned(St1),
            %io:format("=== Load key ~p:~p => ~p~n",[Addr,IKey,hex:encode(St1)]),
            Res
        end,

  State0 = #{ sload=>SLoad,
              gas=>Gas,
              data=>#{
                      address=>binary:decode_unsigned(Address),
                      caller => 1024,
                      origin => 1024
                     }
            },
  Res=try
        Rr=eevm:eval(Bytecode,#{},State0,Function,Params),
        
        Rr
      catch Ec:Ee:Stack ->
              {error, iolist_to_binary(io_lib:format("~p:~p@~p",[Ec,Ee,hd(Stack)]))}
      end,
  FmtStack=fun(St) ->
               [<<"0x",(hex:encode(binary:encode_unsigned(X)))/binary>> || X<-St]
           end,
  gun:close(ConnPid),
  case Res of
    {done, {return,RetVal}, #{stack:=St}} ->
      {return, RetVal, FmtStack(St)};
    {done, 'stop',  #{stack:=St}} ->
      {stop, undefined, FmtStack(St)};
    {done, 'eof', #{stack:=St}} ->
      {eof, undefined, FmtStack(St)};
    {done, 'invalid',  #{stack:=St}} ->
      {error, invalid, FmtStack(St)};
    {done, {revert, Data},  #{stack:=St}} ->
      {revert, Data, FmtStack(St)};
    {error, Desc} ->
      {error, Desc, []};
    {error, nogas, #{stack:=St}} ->
      {error, nogas, FmtStack(St)};
    {error, {jump_to,_}, #{stack:=St}} ->
      {error, bad_jump, FmtStack(St)};
    {error, {bad_instruction,_}, #{stack:=St}} ->
      {error, bad_instruction, FmtStack(St)}
  end.
