# mysql - MySQL connector for [Tarantool][]

[![Build Status](https://travis-ci.org/tarantool/mysql.png?branch=master)](https://travis-ci.org/tarantool/mysql)

## Getting Started

### Prerequisites

 * Tarantool 1.6.5+ with header files (tarantool && tarantool-dev packages)
 * MySQL 5.1 header files (libmysqlclient-dev package)

### Installation

Clone repository and then build it using CMake:

``` bash
git clone https://github.com/tarantool/mysql.git
cd mysql && cmake . -DCMAKE_BUILD_TYPE=RelWithDebugInfo
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
local conn = mysql.connect({host = localhost, user = 'user', pass = 'pass', db = 'db'})
local tuples = conn:execute("SELECT ? AS a, 'xx' AS b", 42))
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
 - `pass` or `password` - a password
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
 - `{ { column1 = value, column2 = value }, ... }, nrows` on success
 - `nil, reason` on error if `raise` is false
 - `error(reason)` on error if `raise` is true

*Example*:
```
tarantool> conn:execute("SELECT ? AS a, 'xx' AS b", 42)
---
- - a: 42
    b: xx
- 1
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

## See Also

 * [Tests][]
 * [Tarantool][]
 * [Tarantool Rocks][TarantoolRocks]

[Tarantool]: http://github.com/tarantool/tarantool
[Tests]: https://github.com/tarantool/mysql/tree/master/test
[TarantoolRocks]: https://github.com/tarantool/rocks
