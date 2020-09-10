# mysql - MySQL connector for [Tarantool][]

[![Build Status](https://travis-ci.org/tarantool/mysql.png?branch=master)](https://travis-ci.org/tarantool/mysql)

## Getting Started

### Prerequisites

* Tarantool 1.6.5+ with header files (tarantool && tarantool-dev /
  tarantool-devel packages).
* MySQL 5.1 header files (libmysqlclient-dev package).
* OpenSSL development package.

If you prefer to install the connector using a system package manager you don't
need to manually install dependencies.

### Installation

#### Build from sources

Clone repository and then build it using CMake:

```sh
git clone https://github.com/tarantool/mysql.git tarantool-mysql
cd tarantool-mysql && cmake . -DCMAKE_BUILD_TYPE=RelWithDebInfo
make
make install
```

#### tarantoolctl rocks

You can also use tarantoolctl rocks:

```sh
tarantoolctl rocks install mysql
```

#### Install a package

[Enable tarantool repository][tarantool_download] and install tarantool-mysql
package:

```sh
apt-get install tarantool-mysql # Debian or Ubuntu
yum install tarantool-mysql     # CentOS
dnf install tarantool-mysql     # Fedora
```

[tarantool_download]: https://www.tarantool.io/en/download/

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

### `conn = mysql.connect(opts)`

Connect to a database.

*Options*:

 - `host` - hostname to connect to
 - `port` - port number to connect to
 - `user` - username
 - `password` - password
 - `db` - database name
 - `use_numeric_result` - provide result of the "conn:execute" as ordered list
   (true/false); default value: false

Throws an error on failure.

*Returns*:

 - `connection ~= nil` on success

### `conn:execute(statement, ...)`

Execute a statement with arguments in the current transaction.

Throws an error on failure.

*Returns*:

 - `results, true` on success, where `results` is in the following form:

(when `use_numeric_result = false` or is not set on a pool/connection creation)

```lua
{
    { -- result set
        {column1 = r1c1val, column2 = r1c2val, ...}, -- row
        {column1 = r2c1val, column2 = r2c2val, ...}, -- row
        ...
    },
    ...
}
```

(when `use_numeric_result = true` on a pool/connection creation)

```lua
{
    { -- result set
        rows = {
            {r1c1val, r1c2val, ...}, -- row
            {r2c1val, r2c2val, ...}, -- row
            ...
        },
        metadata = {
            {type = 'long', name = 'col1'}, -- column meta
            {type = 'long', name = 'col2'}, -- column meta
            ...
        },
    },
    ...
}
```

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

Throws an error on failure.

*Returns*:

 - `quoted_string` on success

### `pool = mysql.pool_create(opts)`

Create a connection pool with count of size established connections.

*Options*:

 - `host` - hostname to connect to
 - `port` - port number to connect to
 - `user` - username
 - `password` - password
 - `db` - database name
 - `size` - count of connections in pool
 - `use_numeric_result` - provide result of the "conn:execute" as ordered list
   (true/false); default value: false

Throws an error on failure.

*Returns*

 - `pool ~= nil` on success

### `conn = pool:get(opts)`

Get a connection from pool. Reset connection before returning it. If connection
is broken then it will be reestablished.
If there is no free connections and timeout is not specified then calling fiber
will sleep until another fiber returns some connection to pool.
If timeout is specified, and there is no free connections for the duration of the timeout,
then the return value is nil.

*Options*:

 - `timeout` - maximum number of seconds to wait for a connection

*Returns*:

 - `conn ~= nil` on success
 - `conn == nil` on there is no free connections when timeout option is specified
 
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
