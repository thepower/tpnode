#! /bin/sh

mkdir -p _build/test/log_chain7

export API_BASE_URL="http://195.3.255.79:43287"


./rebar3 ct --suite=chain7_SUITE \
         --logdir _build/test/log_chain7
export rc=$?


# don't save the logs if everything is OK
#if [ $rc -eq 0 ]
#then
#    rm -rf _build/test/log_chain7/
#    mkdir -p _build/test/log_chain7
#fi

exit $rc
