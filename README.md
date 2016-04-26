# mysql - MySQL connector for [Tarantool][]

[![Build Status](https://travis-ci.org/tarantool/mysql.png?branch=master)](https://travis-ci.org/tarantool/mysql)

## Getting Started

### Prerequisites

 * Tarantool 1.6.5+ with header files (tarantool && tarantool-dev packages)
 * MySQL 5.1 header files (libmysqlclient-dev package)

### Installation

Clone repository and then build it using CMake:

``` bash
git clone https://github.com/tarantool/mysql.git tarantool-mysql
cd tarantool-mysql && cmake . -DCMAKE_BUILD_TYPE=RelWithDebugInfo
make
make install
```

You can also use LuaRocks:

``` bash
luarocks install https://raw.githubusercontent.com/tarantool/mysql/master/mysql-scm-1.rockspec --local
```

See [tarantool/rocks][TarantoolRocks] for LuaRocks configuration details.

### Usage

``` lua
local mysql = require('mysql')
local conn = mysql.connect({host = localhost, user = 'user', password = 'password', db = 'db'})
local status, tuples = conn:execute("SELECT ? AS a, 'xx' AS b", 42))
conn:begin()
conn:execute("INSERT INTO test VALUES(1, 2, 3)")
conn:commit()
```

## API Documentation

### `conn = mysql:connect(opts = {})`

Connect to a database.

*Options*:

 - `host` - a hostname to connect
 - `port` - a port numner to connect
 - `user` - username
 - `password` - a password
 - `db` - a database name
 - `raise` = false - raise an exceptions instead of returning nil, reason in
   all API functions

*Returns*:

 - `connection ~= nil` on success
 - `nil, reason` on error if `raise` is false
 - `error(reason)` on error if `raise` is true

### `conn:execute(statement, ...)`

Execute a statement with arguments in the current transaction.

*Returns*:
 - `true, { { column1 = value, column2 = value }, ... }, { {column1 = value, ... }, ...}` on success
 - `nil, reason` on error if `raise` is false
 - `error(reason)` on error if `raise` is true

*Example*:
```
tarantool> conn:execute("SELECT ? AS a, 'xx' AS b", 42)
---
- - true
- - a: 42
    b: xx
...
```

### `conn:begin()`

Begin a transaction.

*Returns*: `true`

### `conn:commit()`

Commit current transaction.

*Returns*: `true`

### `conn:rollback()`

Rollback current transaction.

*Returns*: `true`

### `conn:ping()`

Execute a dummy statement to check that connection is alive.

*Returns*:

 - `true` on success
 - `false` on failure

### `mysql.pool_create({host = host, port = port, user = user, password = password, db = db, size = size)`

Create a connection pool with count of size established connections.

*Options*:

 - `host` - a hostname to connect
 - `port` - a port numner to connect
 - `user` - username
 - `password` - a password
 - `db` - a database name
 - `raise` = false - raise an exceptions instead of returning nil, reason in
   all API functions
 - `size` - count of connections in pool

*Returns*

 - `pool ~=nil` on success
 - `nil, reason` on error if `raise` is false
 - `error(reason)` on error if `raise` is true

### `pool:get()`

Get a connection from pool. Reset connection before return it. If connection
is broken then it will be reestablished. If there is no free connections then
calling fiber will sleep until another fiber returns some connection to pool.

*Returns*:

 - `connection ~= nil`
 
### `pool:put(conn)`

Return a connection to connection pool.

*Options*

 - `conn` - a connection

## Comments

All calls to connections api will be serialized, so it should to be safe to
use one connection from some count of fibers. But you should understand,
that you can have some unwanted behavior across db calls, for example if
another fiber 'injects' some sql between two your calls.

## See Also

 * [Tests][]
 * [Tarantool][]
 * [Tarantool Rocks][TarantoolRocks]

[Tarantool]: http://github.com/tarantool/tarantool
[Tests]: https://github.com/tarantool/mysql/tree/master/test
[TarantoolRocks]: https://github.com/tarantool/rocks
