#!/bin/sh

CHAIN4="test_c4n1 test_c4n2 test_c4n3"
CHAIN5="test_c5n1 test_c5n2 test_c5n3"
CHAIN6="test_c6n1 test_c6n2 test_c6n3"


not_found() {
    echo "'$1' command not found" >&2
    kill $$
}

check_command() {
    which $1 > /dev/null || not_found $1
}

check_command hostname

HOST=`hostname -s`


is_alive() {
    node=$1

    check_command ps
    check_command grep
    check_command wc

    proc_cnt=`ps axuwww | grep erl_pipes | grep "${node}" | wc -l`
    result=`[ ${proc_cnt} -ge 1 ]`
    return $result
}

start_node() {
    dir=$1
    node=$2

    if is_alive ${node}
    then
        echo skipping alive node ${node}
    else
        echo starting node $node
        export TPNODE_RESTORE=${dir}
        export RELX_CONFIG_PATH="${dir}/${node}.config"
        export VMARGS_PATH="${dir}/${node}.args"
#        echo ${TPNODE_RESTORE}
#        echo ${RELX_CONFIG_PATH}
#        echo ${VMARGS_PATH}
        ./bin/thepower start
    fi
}


start_testnet() {
    for node in $CHAIN4; do start_node ./examples/test_chain4 ${node}; done
    for node in $CHAIN5; do start_node ./examples/test_chain5 ${node}; done
    for node in $CHAIN6; do start_node ./examples/test_chain6 ${node}; done
}

node_pid() {
    node=$1

    check_command ps
    check_command grep
    check_command awk

    pids=`ps axuwww | grep erl_pipes | grep "${node}" | awk '{print \$2;}'`
    pids_cnt=`echo ${pids}|wc -l`

    if [ $pids_cnt -ne 1 ]
    then
        return
    fi

    echo $pids
}

stop_node() {
    node=$1

    check_command kill

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

    check_command rm

    node_host="${node}@${HOST}"
    db_dir="db/db_${node_host}"
    ledger_dir="db/ledger_${node_host}"

    echo "removing ${db_dir}"
    rm -rf "${db_dir}"
    echo "removing ${ledger_dir}"
    rm -rf "${ledger_dir}"
}

reset_testnet() {
    echo "reseting testnet"
    stop_testnet
    for node in ${CHAIN4}; do reset_node ${node}; done
    for node in ${CHAIN5}; do reset_node ${node}; done
    for node in ${CHAIN6}; do reset_node ${node}; done
}

attach_testnet() {
    check_command tmux
    check_command grep
    check_command wc

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

update_testnet() {
    check_command wget
    check_command sed
    check_command uname
    check_command tar
    stop_testnet

    ARCH=`uname -p | sed 's/86_//' | sed 's/aarch/arm/'`

    rm -f thepower-latest*.tar.gz
    wget -c http://dist.thepower.io/thepower-latest-${ARCH}.tar.gz
    tar xvf thepower-latest*.tar.gz
    rm -f thepower-latest*.tar.gz
}

usage() {
    echo "usage: $0 start|stop|attach|reset|update"
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
    update)
        update_testnet
        ;;
    *)
        usage
        exit 1
        ;;
esac


exit 0
