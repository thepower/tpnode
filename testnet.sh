#! /bin/sh

NODES="c1n1 c1n2 c1n3 c2n1 c2n2 c2n3"
# SYNC = 0 — no sync, SYNC = 1 — add -s sync to command line
SYNC=0


is_alive() {
    node=$1
    proc_cnt=`ps axuw | grep erl | grep " ${node}.config" | wc -l`
    result=`[ ${proc_cnt} -ge 1 ]`
    return $result
}

start_testnet() {
    sync_str=""

    if [ $SYNC -eq 1 ]
    then
        sync_str="-s sync"
    fi

    for node in $NODES
    do
        if is_alive ${node}
        then
            echo skipping alive node ${node}
        else
            echo starting node $node
            erl -config ${node}.config -sname ${node} -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager ${sync_str} -s tpnode
        fi
    done
}

node_pid() {
    node=$1

    pids=`ps axuw | grep erl | grep " ${node}.config" | awk '{print \$2;}'`
    pids_cnt=`echo ${pids}|wc -l`

    if [ $pids_cnt -ne 1 ]
    then
        return
    fi

    echo $pids
}

stop_testnet() {
    for node in ${NODES}
    do
        echo stopping node ${node}
        pid=$(node_pid ${node})
#        echo "pid is '${pid}'"
        if [ "${pid}0" -eq 0 ]
        then
            echo unknown pid for node ${node}, skiping it
        else
            echo "sending kill signal to '${node}', pid '${pid}'"
            kill ${pid}
        fi
    done
}


attach_testnet() {
    echo "attach to testnet"

    sessions_cnt=`tmux ls |grep testnet |wc -l`
    if [ "${sessions_cnt}0" -eq 0 ]
    then
#        echo "start new session"
        host=`hostname`
        tmux new-session -d -s testnet -n chain1 "erl -sname cons_c1n1 -hidden -remsh c1n1\@${host}"
        tmux split-window -v -p 67    "erl -sname cons_c1n2 -hidden -remsh c1n2\@${host}"
        tmux split-window -v          "erl -sname cons_c1n3 -hidden -remsh c1n3\@${host}"
        tmux new-window -n chain2     "erl -sname cons_c2n1 -hidden -remsh c2n1\@${host}"
        tmux split-window -v -p 67    "erl -sname cons_c2n2 -hidden -remsh c2n2\@${host}"
        tmux split-window -v          "erl -sname cons_c2n3 -hidden -remsh c2n3\@${host}"
    fi

    tmux a -t testnet:chain1
}

usage() {
    echo "usage: $0 start|stop|attach"
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
    *)
        usage
        exit 1
        ;;
esac


exit 0
