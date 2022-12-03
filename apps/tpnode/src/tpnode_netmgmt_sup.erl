-module(tpnode_netmgmt_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Name) ->
  supervisor:start_link({local, {sup,Name}}, ?MODULE, [Name]).

init([repl_sup]) ->
  Sup={_SupFlags = {simple_one_for_one, 5, 10},
       [
        #{start=>{tpnode_repl_worker,start_link,[]}, id=>simpleid}
       ]
      },
  {ok, Sup};


init([Name]) ->
  Intensity = 2,
  Period = 5,
  Procs = [
           {blockchain2,
            { blockchain_netmgmt, start_link, [Name, #{}]},
            permanent, 5000, worker, []
           %},
           %{ {repl_sup, Name},
           %  { supervisor, start_link, [ ?MODULE, [repl_sup]]},
           %  permanent, 20000, supervisor, []
           %},
           %{ replicator,
           %  { tpnode_netmgmt_repl, start_link, [Name, #{}]},
           %  permanent, 5000, worker, []
           }
          ],
  {ok, {{one_for_one, Intensity, Period}, Procs}}.
