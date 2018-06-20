#! /bin/sh

mkdir -p _build/test/log_chain1
ct_run -pa _build/test/lib/*/ebin \
      -logdir _build/test/log_chain1 \
      -suite chain1_SUITE \
      -noshell

zip -mr _build/test/log_chain1.zip _build/test/log_chain1/
mkdir -p _build/test/log_chain1
mv _build/test/log_chain1.zip _build/test/log_chain1/
