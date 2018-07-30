#!/bin/sh

./bin/testnet.sh reset
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

rm -rf /tmp/ledger_bckups/

exit $rc
