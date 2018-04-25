-module(mkpatches).
-compile(export_all).
-compile(nowarn_export_all).

h2i(H,From,To,Secret) ->
  lists:map(
    fun(N) ->
        Code=scratchpad:geninvite(N,Secret),
        case crypto:hash(md5,Code) of
          H ->
            io:format("~s~n",[Code]);
          _ -> ok
        end
    end, lists:seq(From,To)).

invites_patch(PowDiff,From,To,Secret) ->
      [
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"diff">>], v=>PowDiff},
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"invite">>], v=>1},
       #{t=>set, p=>[<<"current">>, <<"register">>, <<"cleanpow">>], v=>1}
      ]++lists:map(
           fun(N) ->
               Code=scratchpad:geninvite(N,Secret),
               io:format("~s~n",[Code]),
               #{t=><<"list_add">>, p=>[<<"current">>, <<"register">>, <<"invites">>], 
                 v=>crypto:hash(md5,Code)
                }
           end, lists:seq(From,To)).

test_reg_invites() ->
  Patches=[
           #{t=>set, p=>[current, chain, minsig], v=>7},
           #{t=>set, p=>[current, chain, patchsig], v=>7},
           #{t=>set, p=>[current, chain, blocktime], v=>1},
           #{t=>set, p=>[current, chain, allowempty], v=>0},

           #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
           #{t=>set, p=>[current, allocblock, group], v=>10},
           #{t=>set, p=>[current, allocblock, block], v=>101},
           #{t=>set, p=>[current, allocblock, last], v=>0},

           #{t=>set, p=>[<<"current">>, <<"endless">>, 
                         naddress:construct_public(10,101,1),
                         <<"FEE">>], v=>true},
           #{t=>set, p=>[<<"current">>, <<"endless">>, 
                         naddress:construct_public(10,101,2),
                         <<"SK">>], v=>true},
           #{t=>set, p=>[current, fee, params, <<"feeaddr">>], v=>
             naddress:construct_public(10,101,1) },
           #{t=>set, p=>[current, fee, params, <<"notip">>], v=>1},
           #{t=>set, p=>[current, fee, <<"FEE">>, <<"base">>], v=>trunc(1.0e9)},
           #{t=>set, p=>[current, fee, <<"FEE">>, <<"baseextra">>], v=>128},
           #{t=>set, p=>[current, fee, <<"FEE">>, <<"kb">>], v=>trunc(1.0e9)},

           invites_patch(16,0,99,<<"1">>)
          ],
  Patch=scratchpad:sign_patch(
          settings:dmp(
            settings:mp(lists:flatten(Patches))),
          "configs/tnc10/tn101/c101*.config" ),
  Patch.

test_el() ->
  Patches=[
%           #{t=>set, p=>[<<"current">>, <<"endless">>, 
%                         naddress:construct_public(10,101,2),
%                         <<"FEE">>], v=>true},
           #{t=>set, p=>[<<"current">>, <<"endless">>, 
                         naddress:construct_public(10,101,1),
                         <<"SK">>], v=>true}
          ],
  Patch=scratchpad:sign_patch(
          settings:dmp(
            settings:mp(lists:flatten(Patches))),
          "configs/tnc10/tn101/c101*.config" ),
  Patch.
