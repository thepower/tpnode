#!/bin/sh

CHAIN4="${CHAIN4:-test_c4n1 test_c4n2 test_c4n3}"
CHAIN5="${CHAIN5:-test_c5n1 test_c5n2 test_c5n3}"
CHAIN6="${CHAIN6:-test_c6n1 test_c6n2 test_c6n3}"
# SYNC = 0 — no sync, SYNC = 1 — add -s sync to command line for c4n1 node
SYNC=${SYNC-0}

HOST=${HOST-`hostname -s`}



is_alive() {
    node=$1
    proc_cnt=`ps axuwww | grep erl | grep "${node}.config" | wc -l`
    result=`[ ${proc_cnt} -ge 1 ]`
    return $result
}

start_node() {
    dir=$1
    node=$2

    sync_str=""
    if [ $SYNC -eq 1 ]
    then
        sync_str="-s sync"
        export SYNC=0
    fi

    if is_alive ${node}
    then
        echo skipping alive node ${node}
    else
        echo starting node $node
        export TPNODE_RESTORE=${dir}

        erl -config "${dir}/${node}.config" -sname ${node} -detached -noshell -pa _build/test/lib/*/ebin +SDcpu 2:2: -s lager ${sync_str} -s tpnode
    fi

}


start_testnet() {
    CONFIG_ROOT=${CONFIG_ROOT:-./examples}
    for node in $CHAIN4; do start_node ${CONFIG_ROOT}/test_chain4 ${node}; done
    for node in $CHAIN5; do start_node ${CONFIG_ROOT}/test_chain5 ${node}; done
    for node in $CHAIN6; do start_node ${CONFIG_ROOT}/test_chain6 ${node}; done
}

node_pid() {
    node=$1

    pids=`ps axuwww | grep erl | grep "${node}.config" | awk '{print \$2;}'`
    pids_cnt=`echo ${pids}|wc -l`

    if [ $pids_cnt -ne 1 ]
    then
        return
    fi

    echo $pids
}

stop_node() {
    node=$1
    echo stopping node ${node}
    pid=$(node_pid ${node})
#    echo "pid is '${pid}'"
    if [ "${pid}0" -eq 0 ]
    then
        echo unknown pid for node ${node}, skiping it
    else
        echo "sending kill signal to '${node}', pid '${pid}'"
        kill ${pid}
    fi
}

stop_testnet() {
    for node in ${CHAIN4}; do stop_node ${node}; done
    for node in ${CHAIN5}; do stop_node ${node}; done
    for node in ${CHAIN6}; do stop_node ${node}; done
}


reset_node() {
    node=$1

    node_host="${node}@${HOST}"
    db_dir="db/db_${node_host}"
    ledger_dir="db/mledger_${node_host}.db"
    mledger_dir="Mnesia.${node_host}"

    echo "removing ${db_dir}"
    rm -rf "${db_dir}"
    echo "removing ${ledger_dir}"
    rm -rf "${ledger_dir}"
    echo "removing ${mledger_dir}"
    rm -rf "${mledger_dir}"
}

reset_testnet() {
    echo "reseting testnet"
    stop_testnet
    for node in ${CHAIN4}; do reset_node ${node}; done
    for node in ${CHAIN5}; do reset_node ${node}; done
    for node in ${CHAIN6}; do reset_node ${node}; done
    rm -f log/debug_test_* log/error_test_* log/info_test_* log/crash.log log/vmproto_req_* log/uml_test_*
    find ./log -name '*_block_*' -delete
}

attach_testnet() {
    echo "attaching to testnet"

    sessions_cnt=`tmux ls |grep testnet |wc -l`
    if [ "${sessions_cnt}0" -eq 0 ]
    then
#        echo "start new session"
        tmux new-session -d -s testnet -n chain4 "erl -sname cons_c4n1 -hidden -remsh test_c4n1\@${HOST}"
        tmux split-window -v -p 67    "erl -sname cons_c4n2 -hidden -remsh test_c4n2\@${HOST}"
        tmux split-window -v          "erl -sname cons_c4n3 -hidden -remsh test_c4n3\@${HOST}"
        tmux new-window -n chain5     "erl -sname cons_c5n1 -hidden -remsh test_c5n1\@${HOST}"
        tmux split-window -v -p 67    "erl -sname cons_c5n2 -hidden -remsh test_c5n2\@${HOST}"
        tmux split-window -v          "erl -sname cons_c5n3 -hidden -remsh test_c5n3\@${HOST}"
        tmux new-window -n chain6     "erl -sname cons_c6n1 -hidden -remsh test_c6n1\@${HOST}"
        tmux split-window -v -p 67    "erl -sname cons_c6n2 -hidden -remsh test_c6n2\@${HOST}"
        tmux split-window -v          "erl -sname cons_c6n3 -hidden -remsh test_c6n3\@${HOST}"
    fi

    tmux a -t testnet:chain4
}

compile_testnet() {
    stop_testnet
    REBAR_PROFILE=test ./rebar3 compile
}

usage() {
    echo "usage: $0 start|stop|attach|reset|compile"
}

if [ $# -ne 1 ]
then
    usage
    exit 1
fi


case $1 in
    start)
        start_testnet
        ;;
    stop)
        stop_testnet
        ;;
    attach)
        attach_testnet
        ;;
    reset)
        reset_testnet
        ;;
    compile)
        compile_testnet
        ;;
    *)
        usage
        exit 1
        ;;
esac


exit 0
