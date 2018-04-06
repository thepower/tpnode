#! /bin/sh

# killall beam.smp >/dev/null 2>&1

erl -config c1n1.config -sname c1n1 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
erl -config c1n2.config -sname c1n2 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
erl -config c1n3.config -sname c1n3 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
erl -config c2n1.config -sname c2n1 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
erl -config c2n2.config -sname c2n2 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode
erl -config c2n3.config -sname c2n3 -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s sync -s tpnode

sleep 2

tmux new-session -d -s testnet -n chain1 'erl -sname cons_c1n1 -hidden -remsh c1n1@pwr'
tmux split-window -v -p 67    'erl -sname cons_c1n2 -hidden -remsh c1n2@pwr'
tmux split-window -v          'erl -sname cons_c1n3 -hidden -remsh c1n3@pwr'
tmux new-window -n chain2     'erl -sname cons_c2n1 -hidden -remsh c2n1@pwr'
tmux split-window -v -p 67    'erl -sname cons_c2n2 -hidden -remsh c2n2@pwr'
tmux split-window -v          'erl -sname cons_c2n3 -hidden -remsh c2n3@pwr'
tmux a -t testnet:chain1

