-module(genesis2).

-export([priv_file/2,
         pub_file/2,
         init/2,
         make_block/1,
         read_contract/1,
         genesis/1,
         wildcard/3]).

priv_file(Module, KeyName) ->
  Filename=Module:prefix()++KeyName++".priv",
  case file:read_file(Filename) of
    {ok, Bin} ->
      hex:decode(Bin);
    {error,enoent} ->
      Module:key_absend(KeyName, Filename)
  end.

pub_file(Module, KeyName) ->
  Filename=Module:prefix()++KeyName++".pub",
  case file:read_file(Filename) of
    {ok, Bin} ->
      hex:decode(Bin);
    {error,enoent} ->
      Priv=priv_file(Module,KeyName),
      Pub=tpecdsa:calc_pub(Priv),
      file:write_file(Filename,hex:encodex(Pub)),
      Pub
  end.

init(Module, State0) ->
  State1
  = lists:foldl(fun({Address, Field, Path, Value}, Acc) ->
                    pstate:set_state(Address, Field, Path, Value, Acc)
                end, State0, Module:pre_tx()),
  State2
  = lists:foldl(fun
                ({TxBody,GasLimit,Check},Acc) ->
                    {Res, Ret, _GasLeft, Acc1}=process_txs:process_tx(TxBody, GasLimit, Acc, #{}),
                    Check(Res,Ret,Acc1),
                    Acc1;
                ({TxBody,GasLimit},Acc) ->
                  {Res, Ret, _GasLeft, Acc1}=process_txs:process_tx(TxBody, GasLimit, Acc, #{}),
                  if(Res==1) ->
                      Acc1;
                    true ->
                      io:format("TX ~p failed ~p~n",[maps:without([body, hash],TxBody), Ret]),
                      io:format("LOG: ~p~n",[maps:get(log,Acc1)]),
                      throw('tx_failed')
                  end
              end, State1, Module:make_txs()),
  io:format("LOG: ~p~n",[maps:get(log,State2)]),
  io:format("Patch: ~p~n",[pstate:patch(State2)--pstate:patch(State1)]),
  State3
  = lists:foldl(fun({Address, Field, Path, Value}, Acc) ->
                    pstate:set_state(Address, Field, Path, Value, Acc)
                end, State2, Module:post_tx()),
  State3.



make_block(Module) ->
  Generator = fun(LedgerName) ->
                  S0=process_txs:new_state(
                       fun mledger:getfun/2,
                       LedgerName
                      ),
                  Acc=init(Module, S0),
                  P=lists:reverse(pstate:patch(Acc)),
                  {ok,H} = mledger:apply_patch(LedgerName,
                                               mledger:patch_pstate2mledger(
                                                 P
                                                ),
                                               check),
                  {H, P}
              end,
  {LedgerHash, Patch} = mledger:deploy4test(test, [], Generator),
	BlkData=#{
            txs=>[],
            receipt => [],
            parent=><<0:64/big>>,
            mychain=>7,
            height=>0,
            failed=>[],
            temporary=>false,
            ledger_hash=>LedgerHash,
            ledger_patch=>Patch,
            settings=>[],
            extra_roots=>[],
            extdata=>[]
           },
  Blk=block:mkblock2(BlkData),

  % TODO: Remove after testing
  % Verify myself
  % Ensure block may be packed/unapcked correctly
  case block:verify(block:unpack(block:pack(Blk))) of
    {true, _} -> ok;
    false ->
      throw("invalid_block")
  end,
  %end of test block


  Blk.


read_contract(Filename) ->
  {ok,HexBin} = file:read_file(Filename),
  hex:decode(HexBin).

genesis(Module) ->
  Module:node_keys(),
  Blk=make_block(Module),
  SignedBlock=lists:foldl(
    fun(Priv,Acc) ->
        block:sign(Acc,Priv)
    end, Blk, Module:node_privs()),
  file:write_file(Module:prefix() ++ "0.txt",io_lib:format("~p.~n",[SignedBlock])),
  file:write_file(Module:prefix() ++ "0.blk",block:pack(SignedBlock)),
  Blk.

wildcard(Module,Pattern,Ext) ->
  lists:map(
    if Ext=="" ->
         fun(A) -> A end;
       true ->
         fun(A) ->
             {File,Ext}=lists:split(length(A)-length(Ext),A),
             File
         end
    end,
    filelib:wildcard(Pattern++Ext,Module:prefix())
   ).


