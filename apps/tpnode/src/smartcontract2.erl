-module(smartcontract2).

-callback deploy(Tx :: tx:tx(),
         Ledger :: map(),
         GasLimit :: integer(),
         GetFun :: fun(),
         Opaque :: map()) ->
  {'ok', NewLedger :: map(), Opaque::map()} | {'error', Reason::term()}.

-callback handle_tx(Tx :: map(),
          Ledger :: map(),
          GasLimit :: integer(),
          GetFun :: fun(),
          Opaque :: map()) ->
  {'ok',  %success finish, emit new txs
   NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
   GasLeft :: integer(),
   EmitTxs :: list(),
   Opaque :: map()
  } |
  {'ok',  %success finish
   NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
   GasLeft :: integer(),
   Opaque :: map()
  } |
  {'error', %error during execution
   Reason :: 'insufficient_gas' | string(),
   GasLeft :: integer()
  } |
  {'error', %error during start
   Reason :: string()
  }.

-callback info() -> {Name::binary(), Descr::binary()}.
-type args() :: [{Arg::binary(),int|bin|addr}].
-type fa() :: {Method::binary(), Args::args()}|{Method::binary(), Args::args(), Descr::binary()}.
-callback getters() -> [Getter::fa()].
-callback get(Method::binary(), Args::[binary()|integer()], Ledger :: map()) -> [Getter::mfa()].


