#!/bin/sh

set -exu  # Strict shell (w/o -o pipefail)

REPO=${TARANTOOL_REPO:-1.10}

curl -LsSf https://download.tarantool.org/tarantool/${REPO}/gpgkey | sudo apt-key add -
release=`lsb_release -c -s`

sudo rm -f /etc/apt/sources.list.d/*tarantool*.list
sudo tee /etc/apt/sources.list.d/tarantool_${REPO}.list <<- EOF
deb https://download.tarantool.org/tarantool/${REPO}/ubuntu/ $release main
deb-src https://download.tarantool.org/tarantool/${REPO}/ubuntu/ $release main
EOF

sudo apt-get update
sudo apt-get -y install tarantool tarantool-dev

cmake . -DCMAKE_BUILD_TYPE=Debug
make

# Workaround for MariaDB setup of Travis-CI. It has no 'travis'
# user by default.
#
# https://travis-ci.community/t/mariadb-build-error-with-xenial/3160/8
sudo mysql -e "DROP USER IF EXISTS 'travis'@'localhost';"
sudo mysql -e "CREATE USER 'travis'@'localhost';"

sudo mysql -e "CREATE DATABASE tarantool_mysql_test;"
sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'travis'@'localhost' IDENTIFIED BY '';"
export MYSQL=127.0.0.1:3306:travis::tarantool_mysql_test:;

make check
