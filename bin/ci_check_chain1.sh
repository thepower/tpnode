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
fi

exit $rc
