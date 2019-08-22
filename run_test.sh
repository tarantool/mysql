mysql -u root -Bse "CREATE DATABASE tarantool_mysql_test;"
export MYSQL=localhost:3306:root::tarantool_mysql_test ; make check
mysql -u root -Bse "DROP DATABASE tarantool_mysql_test;"
