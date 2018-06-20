#! /bin/sh

mkdir -p _build/test/log_chain1
#ct_run -pa _build/test/lib/*/ebin \
#      -logdir _build/test/log_chain1 \
#      -suite chain1_SUITE \
#      -noshell

./rebar3 ct --suite=chain1_SUITE \
         --logdir _build/test/log_chain1 \
   || exit $?


# don't save the logs if everything is OK
rm -rf _build/test/log_chain1/
mkdir -p _build/test/log_chain1





