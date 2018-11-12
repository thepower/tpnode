#! /bin/sh

export RELEASENAME=thepower-latest-pre
export CHAIN4="alpha_c4n1 alpha_c4n2 alpha_c4n3"
export CHAIN5="alpha_c5n1 alpha_c5n2 alpha_c5n3"
export CHAIN6="alpha_c6n1 alpha_c6n2 alpha_c6n3"
export CONFIG_ROOT=./alpha
export API_BASE_URL="http://127.0.0.1:42841"

./testnet2.sh $1

