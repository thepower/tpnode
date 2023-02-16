-module(tpnode_netmgmt_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).
-export([parse_uri/1]).

% example of service description:
% uri_string:recompose(#{
%                        scheme => "chain",
%                        path => "devneqHrpFF/uGW7wzi4BbFxEz21MIKwacJZ38/s/H0=",
%                        query => uri_string:compose_query(
%                                   [{"n","http://c1023n4.thepower.io:1079/"},
%                                    {"n","http://c1023n1.thepower.io:1079/"}
%                                   ])
%                       }).
% chain:devneqHrpFF/uGW7wzi4BbFxEz21MIKwacJZ38/s/H0=?n=http%3A%2F%2Fc1023n4.thepower.io%3A1079%2F&n=http%3A%2F%2Fc1023n1.thepower.io%3A1079%2F

parse_uri(URI) when is_binary(URI) ->
  #{scheme := Scheme, path := Path, query := Query} = uri_string:parse(URI),
  case Scheme of
    <<"chain">> -> ok;
    _ ->
      throw({invalid_scheme, Scheme})
  end,

  Name=binary_to_atom(Scheme, utf8),
  Genesis=base64:decode(Path),
  QP=uri_string:dissect_query(Query),
  Nodes=lists:foldl(fun({<<"n">>, N}, Acc) ->
                        [N|Acc];
                       (_, Acc) ->
                        Acc
                    end, [], QP),
  #{name => Name,
    genesis => Genesis,
    nodes => Nodes}.

start_link(Name, Url) ->
  supervisor:start_link(?MODULE, [Name, Url]).

init([Name, URI0]) ->
  Intensity = 2,
  Period = 5,

  #{genesis:=Genesis,
    nodes:=NodesBin}=parse_uri(
                    if is_list(URI0) ->
                         list_to_binary(URI0);
                       is_binary(URI0) ->
                         URI0
                    end),
  Nodes=[ binary_to_list(N) || N <- NodesBin],

  Nodes1=case utils:read_cfg(mgmt_cfg,[]) of
            Cfg when is_list(Cfg) ->
             lists:sort(
               fun(_,_) -> rand:uniform()>0.5 end,
               proplists:get_value(http, Cfg, [])++Nodes
              );
            {error, _} ->
             lists:sort(
               fun(_,_) -> rand:uniform()>0.5 end,
               Nodes
              )
          end,

  Nodes2=if length(Nodes1) > 2 -> % Engendra como máximo 2 trabajadores
              {N1,_ } = lists:split(2, Nodes1),
              N1;
            true ->
              Nodes1
         end,

  GetFun=fun({apply_block,#{hash:=_H}=Block}) ->
             gen_server:call(Name,{new_block, Block});
            (last_known_block) ->
             {ok,LBH}=gen_server:call(Name,last_hash),
             LBH;
            (Any) ->
             io:format("requested ~p~n",[Any]),
             throw({unknown_request,Any})
         end,

  Replicators=lists:foldl(
                fun(Node, Acc) ->
                    [{ {replicator,Node},
                       { tpnode_repl_worker, start_link,
                         [#{
                            uri=>Node,
                            check_genesis=>false,
                            getfun => GetFun,
                            repl => {global, {nm, Name}}
                           }]},
                       permanent, 5000, worker, []
                     }|Acc]
                end, [], Nodes2),

  Procs = [
           {blockchain2,
            { blockchain_netmgmt, start_link, [Name, #{ genesis=>Genesis }]},
            permanent, 5000, worker, []
          %  },
          % { {repl_sup, Name},
          %   { supervisor, start_link, [ ?MODULE, [repl_sup]]},
          %   permanent, 20000, supervisor, []
           }, { replicator,
             { tpnode_netmgmt_repl, start_link, [Name, #{}]},
             permanent, 5000, worker, []
           }
          ]++Replicators,
  {ok, {{one_for_one, Intensity, Period}, Procs}}.
