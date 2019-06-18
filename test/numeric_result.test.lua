#!/usr/bin/env tarantool

package.path = "../?/init.lua;./?/init.lua"
package.cpath = "../?.so;../?.dylib;./?.so;./?.dylib"

local mysql = require('mysql')
local tap = require('tap')

local host, port, user, password, db = string.match(os.getenv('MYSQL') or '',
    "([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")

local conn, err = mysql.connect({ host = host, port = port, user = user,
    password = password, db = db, use_numeric_result = true })
if conn == nil then error(err) end

local p, err = mysql.pool_create({ host = host, port = port, user = user,
    password = password, db = db, size = 1, use_numeric_result = true })
if p == nil then error(err) end

function test_mysql_numeric_result(t, conn)
    t:plan(1)
    local results, ok = conn:execute('values (1,2,3),(4,5,6),(7,8,9)')
    local expected = {
        {
            rows = {
                {1, 2, 3},
                {4, 5, 6},
                {7, 8, 9},
            },
            metadata = {
                {type = 'long', name = '1'},
                {type = 'long', name = '2'},
                {type = 'long', name = '3'},
            }
        }
    }

    t:is_deeply({ok, results}, {true, expected}, 'results contain numeric rows')
end

local test = tap.test('use_numeric_result option')
test:plan(2)

test:test('use_numeric_result via connection', test_mysql_numeric_result, conn)

local pool_conn = p:get()
test:test('use_numeric_result via pool', test_mysql_numeric_result, pool_conn)
p:put(pool_conn)
p:close()

os.exit(test:check() == true and 0 or 1)
