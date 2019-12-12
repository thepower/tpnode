In case we want to create new chain we need do the following steps:

* create private keys of nodes
* create chain settings
* create genesis from the data from the previous steps


Use the following code in REPL to create the public key of one node:

K1=tpecdsa:generate_priv().

Put the key to file using the following code:

file:write_file("c8n1.key", K1).

Do these steps again for each node in your chain.

At this point we have generated private keys for all chain nodes.

Let's generate set of patches which become new chain settings.

file:write_file("initgenesis.txt",[io_lib:format("~p.~n",[genesis:settings([{<<"c8n1">>,tpecdsa:calc_pub(K1,true)},{<<"c8n2">>,tpecdsa:calc_pub(K2,true)},{<<"c8n3">>,tpecdsa:calc_pub(K3,true)}])])]).

As you can see in the example we have created the file named initgenesis.txt. We need to edit that file at this point.

We should choose how much node signatures will be sufficient to accept block (minsig). Also we should choose settings for wallets, commissions, gas, endless etc


Here is an example of edited the initgenesis.txt file which contains 8 chain settings:


[#{p => [keys,<<"c8n3">>],
   t => set,
   v =>
       <<3,102,61,117,54,194,75,116,131,253,162,42,110,101,201,32,7,108,154,
         217,232,36,183,147,56,190,215,74,71,167,137,126,189>>},
 #{p => [keys,<<"c8n2">>],
   t => set,
   v =>
       <<3,96,250,170,64,51,90,236,222,152,224,81,16,210,70,253,130,96,23,98,
         248,205,26,213,132,245,161,231,160,151,62,67,245>>},
 #{p => [keys,<<"c8n1">>],
   t => set,
   v =>
       <<3,196,38,152,230,99,73,71,143,46,232,215,43,74,238,216,243,2,54,157,
         200,160,47,53,189,195,128,144,117,185,45,151,236>>},
 #{p => [<<"current">>,chain,patchsigs],t => set,v => 2},
 #{p => [<<"current">>,chain,minsig],t => set,v => 2},
 #{p => [<<"current">>,chain,blocktime],t => set,v => 2},
 #{p => [<<"current">>,chain,<<"allowempty">>],t => set,v => 0},
 #{p => [chains],t => set,v => [1,2,3,7,8]},
 #{p => [nodechain],
   t => set,
   v => #{<<"c8n1">> => 8,<<"c8n2">> => 8,<<"c8n3">> => 8}},
  #{t=><<"nonexist">>, p=>[<<"current">>, <<"allocblock">>, last], v=>any},
  #{t=>set, p=>[<<"current">>, <<"allocblock">>, group], v=>10},
  #{t=>set, p=>[<<"current">>, <<"allocblock">>, block], v=>8},
  #{t=>set, p=>[<<"current">>, <<"allocblock">>, last], v=>0},

  #{t=>set, p=>[<<"current">>, <<"endless">>, <<128,1,64,0,8,0,0,1>>, <<"TST">>], v=>true},
  #{t=>set, p=>[<<"current">>, <<"endless">>, <<128,1,64,0,8,0,0,1>>, <<"SK">>], v=>true},

  #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"feeaddr">>], v=><<128,1,64,0,8,0,0,1>>},
  #{t=>set, p=>[<<"current">>, <<"fee">>, params, <<"notip">>], v=>1},

  #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"base">>], v=>1000000000},
  #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"baseextra">>], v=>128},
  #{t=>set, p=>[<<"current">>, <<"fee">>, <<"SK">>, <<"kb">>], v=>1000000000},
  #{t=>set, p=>[<<"current">>, <<"gas">>, <<"SK">>], v=>100}

].

Let's create genesis from that data. Write in REPL the following code:

{ok,[Sets]}=file:consult("initgenesis.txt").

genesis:new([K1,K2,K3],tx:construct_tx(#{kind=>patch, ver=>2, patches=>Sets})).

At this point you have printed the first block on you screen, and you have created file genesis.txt as well.

