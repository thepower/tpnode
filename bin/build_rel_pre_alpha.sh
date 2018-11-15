#!/bin/sh

BUILD_BRANCH=pre-alpha
BUILD_SUFFIX=pre


ssh root@2001:bc8:4400:2500::24:d0d "cat > build.sh && sh build.sh" << EOF1
cd blochchaintest
. /opt/erl/activate
git fetch origin
git reset --hard
git checkout ${BUILD_BRANCH}
git pull
git describe
rm -rf _build/rel/lib/tpnode
rm -rf _build/default/lib/jsx/ebin/
rm apps/tpnode/include/version.hrl
export VERSION_SUFFIX=${BUILD_SUFFIX}
escript bin/generate_headers
./rebar3 as rel tar
git checkout master
EOF1


ssh root@ascw.cleverfox.ru "cat > build.sh && sh build.sh" << EOF2
cd blochchaintest
. /opt/erl/activate
git fetch origin
git reset --hard
git checkout ${BUILD_BRANCH}
git pull
git describe
rm -rf _build/rel/lib/tpnode
rm -rf _build/default/lib/jsx/ebin/
rm apps/tpnode/include/version.hrl
export VERSION_SUFFIX=${BUILD_SUFFIX}
escript bin/generate_headers
./rebar3 as rel tar
git describe --abbrev=0 | sed 's/^v//'
VER=\$( git describe --abbrev=0 | sed 's/^v//' )
git checkout master
VER1=\$VER-${BUILD_SUFFIX}
echo \$VER -> \$VER1

cp /root/blochchaintest/_build/rel/rel/thepower/thepower-\$VER.tar.gz /var/www/html/thepower-\$VER1-arm64.tar.gz
scp "[2001:bc8:4400:2500::24:d0d]:/root/blochchaintest/_build/rel/rel/thepower/thepower-\$VER.tar.gz" /var/www/html/thepower-\$VER1-x64.tar.gz
echo \$VER1 > /var/www/html/latest-${BUILD_SUFFIX}-x64.txt
echo \$VER1 > /var/www/html/latest-${BUILD_SUFFIX}-arm64.txt

rm -f /var/www/html/thepower-latest-${BUILD_SUFFIX}-arm64.tar.gz
rm -f /var/www/html/thepower-latest-${BUILD_SUFFIX}-x64.tar.gz
ln -s /var/www/html/thepower-\$VER1-x64.tar.gz /var/www/html/thepower-latest-${BUILD_SUFFIX}-x64.tar.gz
ln -s /var/www/html/thepower-\$VER1-arm64.tar.gz /var/www/html/thepower-latest-${BUILD_SUFFIX}-arm64.tar.gz
EOF2


