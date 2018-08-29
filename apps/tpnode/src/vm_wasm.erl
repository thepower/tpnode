-module(vm_wasm).
-export([run/0,run/2,client/2,loop/1,start_link/0]).

run(Host, Port) ->
  spawn(?MODULE,client,[Host, Port]).

run() ->
  {ok,Port}=application:get_env(tpnode, vmport),
  spawn(?MODULE,client,["127.0.0.1", Port]).

start_link() ->
  Pid=run(),
  link(Pid),
  {ok,Pid}.

client(Host, Port) ->
  Executable="wanode",
  case os:find_executable(Executable,code:priv_dir(wanode)) of
    false ->
      lager:error("Can't find ~s",[Executable]);
    Path when is_list(Path) ->
      Handle=erlang:open_port(
             {spawn_executable, Path},
             [{args, ["-h",Host,"-p",integer_to_list(Port)]}, 
              eof,
              stderr_to_stdout
             ]
            ),
      State=#{ port=>Handle },
      loop(State)
  end.

loop(#{port:=Handle}=State) ->
  receive
    {Handle, {data, Msg}} ->
      lager:info("Log ~ts",[Msg]),
      loop(State);
    {Handle, eof} ->
      lager:error("Port went down ~p",[Handle])
  end.

