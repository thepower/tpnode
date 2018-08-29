{nodes, ['test_c4n1@knuth', 'test_c4n2@knuth', 'test_c4n3@knuth',
 'test_c5n1@knuth', 'test_c5n2@knuth', 'test_c5n3@knuth']}.
%{export, "../_build/test/cover/ct.coverdata"}.
{import, "../_build/test/cover/eunit.coverdata"}.
%{incl_app, [tpnode]}.
{incl_mods, [address,address_db,apixiom,bal,base58,beacon,bin2hex,
  block,blockchain,blockvote,bron_kerbosch,bsig,
  chainsettings,contract_chainfee,contract_erltest,
  contract_nft,contract_test,contract_wasm,discovery,
  generate_block,genesis,hashqueue,hex,
  httpapi_playground,interconnect,ldb,ledger,
  ledger_sync,mkblock,mkblock_benchmark,mkpatches,
  naddress,nodekey,rdb_dispatcher,scratchpad,settings,
  smartcontract,smartcontract2,smartcontract_scratchpad,
  synchronizer,test_sync,topology,tpecdsa,
  tpic_checkauth,tpnode,tpnode_announcer,tpnode_bridge,
  tpnode_cert,tpnode_http,tpnode_httpapi,
  tpnode_registry,tpnode_sup,tpnode_tpic_handler,
  tpnode_vmproto,tpnode_vmsrv,tpnode_ws,
  tpnode_ws_dispatcher,tx,tx1,tx_visualizer,txgen,
  txpool,txstatus,utils,vm,vm_erltest,vm_wasm,xchain,
  xchain_api,xchain_client,xchain_client_handler,
  xchain_client_worker,xchain_dispatcher,xchain_server,
  xchain_server_handler]}.
{level, details}.
{incl_dirs_r, ["../apps"]}.
%{src_dirs, tpnode, ["apps/tpnode/src"]}.
%{excl_dirs_r, ["test"]}.

