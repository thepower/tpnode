#! /bin/sh

mkdir -p _build/test/log_chain4

./rebar3 ct --suite=chain4_SUITE \
         --logdir _build/test/log_chain4
export rc=$?


# don't save the logs if everything is OK
#if [ $rc -eq 0 ]
#then
#    rm -rf _build/test/log_chain4/
#    mkdir -p _build/test/log_chain4
#fi

exit $rc
