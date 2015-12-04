sudo apt-get update
uname -a
lsb_release -c -s

curl http://tarantool.org/dist/public.key | sudo apt-key add -
echo "deb http://tarantool.org/dist/master/ubuntu/ `lsb_release -c -s` main" | sudo tee -a /etc/apt/sources.list.d/tarantool.list
sudo apt-get update > /dev/null
sudo apt-get -q -y install tarantool tarantool-dev
sudo apt-get -q -y install libmysqlclient-dev

mysql -e "CREATE USER 'tarantool'@'localhost' IDENTIFIED BY 'tarantool';" -u root
mysql -e "CREATE DATABASE tarantool;" -u root
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'tarantool'@'localhost' WITH GRANT OPTION;" -u root
export MYSQL='127.0.0.1:3306:tarantool:tarantool:tarantool'

cmake . -DCMAKE_BUILD_TYPE=RelWithDebugInfo
make
make test
