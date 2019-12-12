#! /bin/sh

mkdir -p _build/test/log_chain1
#ct_run -pa _build/test/lib/*/ebin \
#      -logdir _build/test/log_chain1 \
#      -suite chain1_SUITE \
#      -noshell

./rebar3 ct --suite=chain1_SUITE \
         --logdir _build/test/log_chain1
export rc=$?


# don't save the logs if everything is OK
if [ $rc -eq 0 ]
then
    rm -rf _build/test/log_chain1/
    mkdir -p _build/test/log_chain1
else
    echo "test failed"
#        for ip in "2001:bc8:4700:2500::131f" "2001:bc8:4700:2500::121b" "2001:bc8:4400:2700::1263" "2001:bc8:4400:2700::1265" "2001:bc8:4400:2700::2341"
#        do
#            (
#            ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$ip "cd thepower; . /opt/erl/activate;  ./bin/thepower eval 'blockchain ! runsync.'"
#             ) &
#        done
fi

exit $rc
