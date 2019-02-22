#!/bin/sh

# reset the testnet
./bin/testnet.sh reset >/dev/null

# remove old logs
rm -rf ./log
mkdir ./log
touch ./log/.keepme

rm -rf ./_build/test/logs
mkdir -p ./_build/test/logs

# run tests
make cover
export rc=$?

# don't save the logs if everything is OK
if [ $rc -ne 0 ]
then
    # stop testnet in case of error
    ./bin/testnet.sh stop >/dev/null
    # save db to artifacts
    echo "tests failed, saving ledger bckups"
    tar cfj log/test_ledger_bckups.tar.bz2 /tmp/ledger_bckups/ >/dev/null
    tar cfj log/test_blockdebug.tar.bz2 ./log/*_block_* >/dev/null
fi

# save logs
tar cfj log/test_logs.tar.bz2 ./log/*.log ./log/*.blog
find ./log -name '*.log' -delete

# cleanup
rm -rf /tmp/ledger_bckups/
rm -rf ./log/vmproto_req_*
find ./log -name '*_block_*' -delete

# send stop signal to testnet once again
./bin/testnet.sh stop >/dev/null

exit $rc
