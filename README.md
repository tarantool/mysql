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
cd tarantool-mysql && cmake . -DCMAKE_BUILD_TYPE=RelWithDebInfo
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
local pool = mysql.pool_create({ host = '127.0.0.1', user = 'user', password = 'password', db = 'db', size = 5 })
local conn = pool:get()
local tuples, status  = conn:execute("SELECT ? AS a, 'xx' AS b, NULL as c", 42))
conn:begin()
conn:execute("INSERT INTO test VALUES(1, 2, 3)")
conn:commit()
pool:put(conn)
```

## API Documentation

### `conn = mysql.connect(opts = {})`

Connect to a database.

*Options*:

 - `host` - hostname to connect to
 - `port` - port number to connect to
 - `user` - username
 - `password` - password
 - `db` - database name

*Returns*:

 - `connection ~= nil` on success
 - `error(reason)` on error

### `conn:execute(statement, ...)`

Execute a statement with arguments in the current transaction.

*Returns*:
 - `{ { { column1 = value, column2 = value }, ... }, { {column1 = value, ... }, ...}, ...}, true` on success
 - `error(reason)` on error

*Example*:
```
tarantool> conn:execute("SELECT ? AS a, 'xx' AS b", 42)
---
- - - a: 42
      b: xx
- true
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

### `conn:quote()`

Quote a query string.

*Returns*:

 - `quoted_string` on success
 - `error(reason)` on error

### `pool = mysql.pool_create(opts = {})`

Create a connection pool with count of size established connections.

*Options*:

 - `host` - hostname to connect to
 - `port` - port number to connect to
 - `user` - username
 - `password` - password
 - `db` - database name
 - `size` - count of connections in pool

*Returns*

 - `pool ~=nil` on success
 - `error(reason)` on error

### `conn = pool:get()`

Get a connection from pool. Reset connection before returning it. If connection
is broken then it will be reestablished. If there is no free connections then
calling fiber will sleep until another fiber returns some connection to pool.

*Returns*:

 - `conn ~= nil`
 
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
