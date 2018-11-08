#! /bin/sh

if [ ! -f ./bin/testnet.sh ]
then
    echo "can't find testnet control utility"
    exit -1
fi

export CHAIN4="alpha_c4n1 alpha_c4n2 alpha_c4n3"
export CHAIN5="alpha_c5n1 alpha_c5n2 alpha_c5n3"
export CHAIN6="alpha_c6n1 alpha_c6n2 alpha_c6n3"
export CONFIG_ROOT=./alpha
export API_BASE_URL="http://127.0.0.1:42841"

rm -rf ./alpha
mkdir -p ./alpha
cp -a ./examples/* ./alpha/

# changing the node name
find ./alpha -type f -name "*.args" -print0 | xargs -0 sed -i'' -e 's/test/alpha/g'

# changing the port number
find ./alpha -type f -name "*.conf" -print0 | xargs -0 sed -i'' -e 's/49\([0-9][0-9][0-9]\)/42\1/g'

# changing the config path
find ./alpha -type f -name "*.config" -print0 | xargs -0 sed -i'' -e 's#./examples/#./alpha/#g'

# rename files
for file in $(find ./alpha -type f -name "test_c*")
do
   mv $file $(echo "$file" | sed 's/\(test_c\)\([0-9]\+n[0-9]\+\)/alpha_c\2/g')
done

./bin/testnet.sh $1

