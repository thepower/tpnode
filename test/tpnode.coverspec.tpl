{nodes, ['test_c4n1@knuth', 'test_c4n2@knuth', 'test_c4n3@knuth',
 'test_c5n1@knuth', 'test_c5n2@knuth', 'test_c5n3@knuth']}.
%{export, "../_build/test/cover/ct.coverdata"}.
{import, "../_build/test/cover/eunit.coverdata"}.
%{incl_app, [tpnode]}.
{incl_mods, [address,address_db,apixiom,bal,base58,beacon,bin2hex,block,blockchain,
 blockchain_reader,blockchain_sync,blockchain_updater,blockvote,bron_kerbosch,
 bsig,chainkeeper,chainsettings,contract_erltest,contract_evm,
 contract_wasm,discovery,fairshare,generate_block,generate_block_process,
 genesis,genesis_easy,genuml,hashqueue,hex,httpapi_playground,
 interconnect,ldb,ledger_sync,maphash,mbal,mkblock,
 mkblock_genblk,mkpatches,mledger,naddress,nodekey,rdb_dispatcher,scratchpad,
 settings,smartcontract,smartcontract2,synchronizer,
 topology,tpecdsa,tpic_checkauth,tpnode,tpnode_announcer,
 tpnode_cert,tpnode_dtx_runner,tpnode_http,tpnode_httpapi,tpnode_sup,
 tpnode_tpic_handler,tpnode_txstorage,tpnode_txsync,tpnode_vmproto,
 tpnode_vmsrv,tpnode_ws,tpnode_ws_dispatcher,tx,tx1,tx_visualizer,txlog,
 txpool,txqueue,txstatus,utils,vm,vm_erltest,vm_wasm,xchain,xchain_api,
 xchain_client,xchain_client_handler,xchain_client_worker,xchain_dispatcher,
 xchain_server,xchain_server_handler]}.
{level, details}.
{incl_dirs_r, ["../apps"]}.
%{src_dirs, tpnode, ["apps/tpnode/src"]}.
%{excl_dirs_r, ["test"]}.

