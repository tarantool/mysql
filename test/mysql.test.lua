#!/usr/bin/env tarantool

package.path = "../?/init.lua;./?/init.lua"
package.cpath = "../?.so;../?.dylib;./?.so;./?.dylib"

local mysql = require('mysql')
local json = require('json')
local tap = require('tap')
local f = require('fiber')

local host, port, user, password, db = string.match(os.getenv('MYSQL') or '',
    "([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")

local conn, err = mysql.connect({ host = host, port = port, user = user,
    password = password, db = db })
if conn == nil then error(err) end

local p, err = mysql.pool_create({ host = host, port = port, user = user,
    password = password, db = db, size = 2 })

function test_old_api(t, conn)
    t:plan(16)
    -- Add an extension to 'tap' module
    getmetatable(t).__index.q = function(test, stmt, result, ...)
        test:is_deeply({conn:execute(stmt, ...)}, {{result}, true},
            ... ~= nil and stmt..' % '..json.encode({...}) or stmt)
    end
    t:ok(conn:ping(), "ping")
    t:q("SELECT '123' AS bla, 345", {{ bla = '123', ['345'] = 345 }})
    t:q('SELECT -1 AS neg, NULL AS abc', {{ neg = -1 }})
    t:q('SELECT -1.1 AS neg, 1.2 AS pos', {{ neg = "-1.1", pos = "1.2" }})
    t:q('SELECT ? AS val', {{ val = 'abc' }}, 'abc')
    t:q('SELECT ? AS val', {{ val = '1' }}, '1')
    t:q('SELECT ? AS val', {{ val = 123 }},123)
    t:q('SELECT ? AS val', {{ val = 1 }}, true)
    t:q('SELECT ? AS val', {{ val = 0 }}, false)
    t:q('SELECT ? AS val, ? AS num, ? AS str',
        {{ val = 0, num = 123, str = 'abc'}}, false, 123, 'abc')
    t:q('SELECT ? AS bool1, ? AS bool2, ? AS nil, ? AS num, ? AS str',
        {{ bool1 = 1, bool2 = 0, num = 123, str = 'abc' }}, true, false, nil,
        123, 'abc')
    t:q('SELECT 1 AS one UNION ALL SELECT 2', {{ one = 1}, { one = 2}})

    t:test("tx", function(t)
        t:plan(8)
        if not conn:execute("CREATE TEMPORARY TABLE _tx_test (a int)") then
            return
        end

        t:ok(conn:begin(), "begin")
        local _, status = conn:execute("INSERT INTO _tx_test VALUES(10)");
        t:is(status, true, "insert")
        t:q('SELECT * FROM _tx_test', {{ a  = 10 }})
        t:ok(conn:rollback(), "roolback")
        t:q('SELECT * FROM _tx_test', {})

        t:ok(conn:begin(), "begin")
        conn:execute("INSERT INTO _tx_test VALUES(10)");
        t:ok(conn:commit(), "commit")
        t:q('SELECT * FROM _tx_test', {{ a  = 10 }})

        conn:execute("DROP TABLE _tx_test")
    end)

    t:q('DROP TABLE IF EXISTS unknown_table', nil)
    local status, reason = pcall(conn.execute, conn, 'DROP TABLE unknown_table')
    t:like(reason, 'unknown_table', 'error')
    t:ok(conn:close(), "close")
end

function test_gc(t, p)
    t:plan(1)
    p:get()
    local c = p:get()
    c = nil
    collectgarbage('collect')
    t:is(p.queue:count(), p.size, 'gc connections')
end

function test_conn_fiber1(c, q)
    for i = 1, 10 do
        c:execute('SELECT sleep(0.05)')
    end
    q:put(true)
end

function test_conn_fiber2(c, q)
    for i = 1, 25 do
        c:execute('SELECT sleep(0.02)')
    end
    q:put(true)
end

function test_conn_concurrent(t, p)
    t:plan(1)
    local c = p:get()
    local q = f.channel(2)
    local t1 = f.time()
    f.create(test_conn_fiber1, c, q)
    f.create(test_conn_fiber2, c, q)
    q:get()
    q:get()
    p:put(c)
    t:ok(f.time() - t1 >= 0.95, 'concurrent connections')
end


function test_mysql_int64(t, p)
    t:plan(1)
    conn = p:get()
    conn:execute('create table int64test (id bigint)')
    conn:execute('insert into int64test values(1234567890123456789)')
    local d, s = conn:execute('select id from int64test')
    conn:execute('drop table int64test')
    t:ok(d[1][1]['id'] == 1234567890123456789LL, 'int64 test')
    p:put(conn)
end

tap.test('connection old api', test_old_api, conn)
local pool_conn = p:get()
tap.test('connection old api via pool', test_old_api, pool_conn)
p:put(pool_conn)
tap.test('test collection connections', test_gc, p)
tap.test('connection concurrent', test_conn_concurrent, p)
tap.test('int64', test_mysql_int64, p)
p:close()

