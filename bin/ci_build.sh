#!/bin/sh

# reset the testnet
./bin/testnet.sh reset

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
    ./bin/testnet.sh stop
    # save db to artifacts
    echo "tests failed, saving ledger bckups"
    tar cfj log/test_ledger_bckups.tar.bz2 /tmp/ledger_bckups/
fi

# cleanup
rm -rf /tmp/ledger_bckups/

exit $rc
