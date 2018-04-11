-module(chainsettings).

-export([get/2,get/3]).

get(Key, Settings) ->
  get(Key, Settings, fun() ->
               {Chain, _}=gen_server:call(blockchain, last_block_height, 500),
               true=is_integer(Chain)
           end).


get(allowempty, Settings, GetChain) ->
  get(<<"allowempty">>, Settings, GetChain);

get(patchsig, Settings, GetChain) ->
  case settings:get([<<"current">>,chain,<<"patchsig">>],Settings) of
    I when is_integer(I) ->
      I;
    _ ->
      case settings:get([<<"current">>,chain,minsig],Settings) of
        I when is_integer(I) ->
          I;
        _ ->
          try
            Chain=GetChain(),
            R=settings:get([chain,Chain,minsig],Settings),
            true=is_integer(R),
            R
          catch _:_ ->
                  3
          end
      end
  end;


get(Name, Sets, GetChain) ->
  MinSig=settings:get([<<"current">>,chain,Name], Sets),
  if is_integer(MinSig) -> MinSig;
     true ->
       MinSig_old=settings:get([chain,GetChain(),Name], Sets),
       if is_integer(MinSig_old) -> 
            lager:info("Got setting ~p from deprecated place",[Name]),
            MinSig_old;
          true -> undefined
       end
  end.

