#!/usr/bin/env tarantool

package.path = "../?/init.lua;./?/init.lua"
package.cpath = "../?.so;../?.dylib;./?.so;./?.dylib"

local mysql = require('mysql')
local json = require('json')
local tap = require('tap')
local fiber = require('fiber')
local fio = require('fio')
local ffi = require('ffi')

local host, port, user, password, db = string.match(os.getenv('MYSQL') or '',
    "([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")

local conn, err = mysql.connect({ host = host, port = port, user = user,
    password = password, db = db })
if conn == nil then error(err) end

local p, err = mysql.pool_create({ host = host, port = port, user = user,
    password = password, db = db, size = 2 })
if p == nil then error(err) end

local function test_old_api(t, conn)
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
    local _, reason = pcall(conn.execute, conn, 'DROP TABLE unknown_table')
    t:like(reason, 'unknown_table', 'error')
    t:ok(conn:close(), "close")
end

local function test_gc(test, pool)
    test:plan(3)

    -- Case: verify that a pool tracks connections that are not
    -- put back, but were collected by GC.
    test:test('loss a healthy connection', function(test)
        test:plan(1)

        assert(pool.size >= 2, 'test case precondition fails')

        -- Loss one connection.
        pool:get()

        -- Loss another one.
        local conn = pool:get() -- luacheck: no unused
        conn = nil

        -- Collect lost connections.
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that a pool is aware of collected connections.
        test:is(pool.queue:count(), pool.size, 'all connections are put back')
    end)

    -- Case: the same, but for broken connection.
    test:test('loss a broken connection', function(test)
        test:plan(2)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection, make a bad query and loss the
        -- connection.
        local conn = pool:get()
        local ok = pcall(conn.execute, conn, 'bad query')
        test:ok(not ok, 'a query actually fails')
        conn = nil -- luacheck: no unused

        -- Collect the lost connection.
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that a pool is aware of collected connections.
        test:is(pool.queue:count(), pool.size, 'all connections are put back')
    end)

    -- Case: the same, but for closed connection.
    test:test('loss a closed connection', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection, close it and loss the connection.
        local conn = pool:get()
        conn:close()
        conn = nil -- luacheck: no unused

        -- Collect the lost connection.
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that a pool is aware of collected connections.
        test:is(pool.queue:count(), pool.size, 'all connections are put back')
    end)
end

local function test_conn_fiber1(c, q)
    for _ = 1, 10 do
        c:execute('SELECT sleep(0.05)')
    end
    q:put(true)
end

local function test_conn_fiber2(c, q)
    for _ = 1, 25 do
        c:execute('SELECT sleep(0.02)')
    end
    q:put(true)
end

local function test_conn_concurrent(t, p)
    t:plan(1)
    local c = p:get()
    local q = fiber.channel(2)
    local t1 = fiber.time()
    fiber.create(test_conn_fiber1, c, q)
    fiber.create(test_conn_fiber2, c, q)
    q:get()
    q:get()
    p:put(c)
    t:ok(fiber.time() - t1 >= 0.95, 'concurrent connections')
end

local function test_mysql_int64(t, p)
    t:plan(1)
    local conn = p:get()
    conn:execute('create table int64test (id bigint)')
    conn:execute('insert into int64test values(1234567890123456789)')
    local d, _ = conn:execute('select id from int64test')
    conn:execute('drop table int64test')
    t:ok(d[1][1]['id'] == 1234567890123456789LL, 'int64 test')
    p:put(conn)
end

local function test_connection_pool(test, pool)
    test:plan(11)

    -- {{{ Case group: all connections are consumed initially.

    assert(pool.queue:is_full(), 'case group precondition fails')

    -- Grab all connections from a pool.
    local connections = {}
    for _ = 1, pool.size do
        table.insert(connections, pool:get())
    end

    -- Case: get and put connections from / to a pool.
    test:test('pool:get({}) and pool:put()', function(test)
        test:plan(2)
        assert(pool.queue:is_empty(), 'test case precondition fails')

        -- Verify that we're unable to get one more connection.
        local latch = fiber.channel(1)
        local conn
        fiber.create(function()
            conn = pool:get()
            latch:put(true)
        end)
        local res = latch:get(1)
        test:is(res, nil, 'unable to get more connections then a pool size')

        -- Give a connection back and verify that now the fiber
        -- above gets this connection.
        pool:put(table.remove(connections))
        latch:get()
        test:ok(conn ~= nil, 'able to get a connection when it was given back')

        -- Restore everything as it was.
        table.insert(connections, conn)
        conn = nil -- luacheck: no unused

        assert(pool.queue:is_empty(), 'test case postcondition fails')
    end)

    -- Case: get a connection with a timeout.
    test:test('pool:get({timeout = <...>})', function(test)
        test:plan(3)
        assert(pool.queue:is_empty(), 'test case precondition fails')

        -- Verify that we blocks until reach a timeout, then
        -- unblocks and get `nil` as a result.
        local latch = fiber.channel(1)
        local conn
        fiber.create(function()
            conn = pool:get({timeout = 2})
            latch:put(true)
        end)
        local res = latch:get(1)
        test:is(res, nil, 'pool:get() blocks until a timeout')
        local res = latch:get()
        test:ok(res ~= nil, 'pool:get() unblocks after a timeout')
        test:is(conn, nil, 'pool:get() returns nil if a timeout was reached')

        assert(pool.queue:is_empty(), 'test case postcondition fails')
    end)

    -- Give all connections back to the poll.
    for _, conn in ipairs(connections) do
        pool:put(conn)
    end

    assert(pool.queue:is_full(), 'case group postcondition fails')

    -- }}}

    -- {{{ Case group: all connections are ready initially.

    assert(pool.queue:is_full(), 'case group precondition fails')

    -- XXX: Maybe the cases below will look better if rewrite them
    --      in a declarative way, like so:
    --
    --      local cases = {
    --          {
    --              'case name',
    --              after_get = function(test, context)
    --                  -- * Do nothing.
    --                  -- * Or make a bad query (and assert that
    --                  --   :execute() fails).
    --                  -- * Or close the connection.
    --              end,
    --              after_put = function(test, context)
    --                  -- * Do nothing.
    --                  -- * Or loss `context.conn` and trigger
    --                  --   GC.
    --              end,
    --          }
    --      }
    --
    --      Or so:
    --
    --      local cases = {
    --          {
    --              'case name',
    --              after_get = function(test, context)
    --                  -- * Do nothing.
    --                  -- * Or make a bad query (and assert that
    --                  --   :execute() fails).
    --                  -- * Or close the connection.
    --              end,
    --              loss_after_put = <boolean>,
    --          }
    --      }
    --
    --      `loss_after_put` will do the following after put (see
    --      comments in cases below):
    --
    --      context.conn = nil
    --      collectgarbage('collect')
    --      assert(pool.queue:is_full(), <...>)
    --      local item = pool.queue:get()
    --      pool.queue:put(item)
    --      test:ok(true, <...>)

    -- Case: get a connection and put it back.
    test:test('get and put a connection', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection.
        local conn = pool:get()

        -- Put the connection back and verify that the pool is full.
        pool:put(conn)
        test:ok(pool.queue:is_full(), 'a connection was given back')
    end)

    -- Case: the same, but loss and collect a connection after
    -- put.
    test:test('get, put and loss a connection', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection.
        local conn = pool:get()

        -- Put the connection back, loss it and trigger GC.
        pool:put(conn)
        conn = nil -- luacheck: no unused
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that the pool is full.
        test:ok(pool.queue:is_full(), 'a connection was given back')
    end)

    -- Case: get a connection, broke it and put back.
    test:test('get, broke and put a connection', function(test)
        test:plan(2)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection and make a bad query.
        local conn = pool:get()
        local ok = pcall(conn.execute, conn, 'bad query')
        test:ok(not ok, 'a query actually fails')

        -- Put the connection back and verify that the pool is full.
        pool:put(conn)
        test:ok(pool.queue:is_full(), 'a broken connection was given back')
    end)

    -- Case: the same, but loss and collect a connection after
    -- put.
    test:test('get, broke, put and loss a connection', function(test)
        test:plan(2)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection and make a bad query.
        local conn = pool:get()
        local ok = pcall(conn.execute, conn, 'bad query')
        test:ok(not ok, 'a query actually fails')

        -- Put the connection back, loss it and trigger GC.
        pool:put(conn)
        conn = nil -- luacheck: no unused
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that the pool is full
        test:ok(pool.queue:is_full(), 'a broken connection was given back')
    end)

    -- Case: get a connection and close it.
    test:test('get and close a connection', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection and close it.
        local conn = pool:get()
        conn:close()

        test:ok(pool.queue:is_full(), 'a connection was given back')
    end)

    -- Case: the same, but loss and collect a connection after
    -- close.
    test:test('get, close and loss a connection', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection and close it.
        local conn = pool:get()
        conn:close()

        conn = nil -- luacheck: no unused
        collectgarbage('collect')
        collectgarbage('collect')

        -- Run a fiber scheduler cycle to finish gc process.
        fiber.yield()

        -- Verify that the pool is full
        test:ok(pool.queue:is_full(), 'a broken connection was given back')
    end)

    -- Case: get a connection, close and put it back.
    test:test('get, close and put a connection', function(test)
        test:plan(2)

        assert(pool.size >= 1, 'test case precondition fails')

        -- Get a connection.
        local conn = pool:get()

        conn:close()
        test:ok(pool.queue:is_full(), 'a connection was given back')

        -- Put must throw an error.
        local res = pcall(pool.put, pool, conn)
        test:ok(not res, 'an error is thrown on "put" after "close"')
    end)

     -- Case: close the same connection twice.
    test:test('close a connection twice', function(test)
        test:plan(2)

        assert(pool.size >= 1, 'test case precondition fails')

        local conn = pool:get()
        conn:close()
        test:ok(pool.queue:is_full(), 'a connection was given back')

        local res = pcall(conn.close, conn)
        test:ok(not res, 'an error is thrown on double "close"')
    end)

    -- Case: put the same connection twice.
    test:test('put a connection twice', function(test)
        test:plan(3)

        assert(pool.size >= 2, 'test case precondition fails')

        local conn_1 = pool:get()
        local conn_2 = pool:get()
        pool:put(conn_1)

        test:ok(not pool.queue:is_full(),
                'the same connection has not been "put" twice')

        local res = pcall(pool.put, pool, conn_1)
        test:ok(not res, 'an error is thrown on double "put"')

        pool:put(conn_2)
        test:ok(pool.queue:is_full(),
                'all connections were returned to the pool')
    end)

    assert(pool.queue:is_full(), 'case group postcondition fails')

    -- }}}
end

local function test_connection_reset(test, pool)
    test:plan(2)

    assert(pool.queue:is_full(), 'test case precondition fails')

    -- Case: valid credentials were used to "reset" the connection
    test:test('reset connection successfully', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        local conn = pool:get()
        conn:reset(pool.user, pool.pass, pool.db)
        test:ok(conn:ping(), 'connection "reset" successfully')
        pool:put(conn)
    end)

    -- Case: invalid credentials were used to "reset" the connection
    test:test('reset connection failed', function(test)
        test:plan(1)

        assert(pool.size >= 1, 'test case precondition fails')

        local conn = pool:get()
        local check = pcall(conn.reset, conn, "guinea pig", pool.pass, pool.db)
        test:ok(not check, 'connection "reset" fails')
        pool:put(conn)
    end)

    assert(pool.queue:is_full(), 'test case postcondition fails')
end

local function test_underlying_conn_closed_during_gc(test)
    test:plan(1)
    if jit.os ~= 'Linux' then
        test:skip('non-Linux OS')
        return
    end
    -- Basing on the statement, that file descriptors are recycled
    -- in ascending order. It means, that if we call open() and
    -- immediately close(), we get the first vacant index for a
    -- new resource in the file descriptor table. It is important
    -- not to call any procedures between open() and close() that
    -- may affect the file descriptor table. After that, we
    -- immediately create connection, which creates a socket.
    -- Socket is a resource, which occupies the first vacant index
    -- in the file descriptor table. We check that the socket is
    -- indeed destroyed by using fcntl() for this index (handle).
    -- See: https://www.win.tue.nl/~aeb/linux/vfs/trail-2.html
    local fh, err = fio.open('/dev/zero', {'O_RDONLY'})
    if fh == nil then error(err) end
    local handle = fh.fh
    fh:close()
    local conn, err = mysql.connect({ host = host, port = port, user = user,
        password = password, db = db })
    if conn == nil then error(err) end

    -- Somehow we lost the connection handle.
    conn = nil
    collectgarbage('collect')
    collectgarbage('collect')

    -- Run a fiber scheduler cycle to finish gc process.
    fiber.yield()

    ffi.cdef([[ int fcntl(int fd, int cmd, ...); ]])
    local F_GETFD = 1
    test:ok(ffi.C.fcntl(handle, F_GETFD) == -1, 'descriptor is closed')
end

local function test_ffi_null_printing(test, pool)
    test:plan(4)
    local function json_result(keep_null, prepared)
        local conn, err = mysql.connect({host = host, port = port, user = user,
            password = password, db = db, keep_null = keep_null})
        if conn == nil then error(err) end
        local rows
        if prepared then
            rows = conn:execute('SELECT 1 AS w, ? AS x', nil)
        else
            rows = conn:execute('SELECT 1 AS w, NULL AS x')
        end
        return json.encode(rows)
    end
    local res = json_result(true, true)
    test:ok(res == '[[{"x":null,"w":1}]]', 'execute_prepared keep_null enabled')
    res = json_result(false, true)
    test:ok(res == '[[{"w":1}]]', 'execute_prepared keep_null disabled')
    res = json_result(true, false)
    test:ok(res == '[[{"x":null,"w":1}]]', 'execute keep_null enabled')
    res = json_result(false, false)
    test:ok(res == '[[{"w":1}]]', 'execute keep_null disabled')
end

--- gh-34: Check that fiber is not blocked in the following case.
-- A connection conn is acquired from a pool and we acquire a
-- lock. Then we start the first fiber with pool:put(conn), which
-- try to acquire lock and yield. Then the second fiber is started
-- to perform conn:execute(), conn:reset() or conn:quote() which
-- try to acquire lock, because the connection is still marked as
-- 'usable' and yield too. It's appeared that the lock is never
-- released. Now, it's fixed.
-- In the case of conn:close() check that error message is proper.
local function test_block_fiber_inf(test, pool)
    test:plan(7)

    local function fiber_block_execute(conn)
        local res, err = pcall(conn.execute, conn, 'SELECT "a"')
        test:ok(res == false and string.find(err, 'Connection is not usable'),
            'execute failed')
    end

    local function fiber_block_reset(conn, pool)
        local res, err = pcall(conn.reset, conn, pool.user, pool.pass, pool.db)
        test:ok(res == false and string.find(err, 'Connection is not usable'),
            'reset failed')
    end

    local function fiber_block_quote(conn, pool)
        local res, err = pcall(conn.quote, conn, 1)
        test:ok(res == false and string.find(err, 'Connection is not usable'),
            'quote failed')
    end

    local timeout = 5
    local cases = {fiber_block_execute, fiber_block_reset, fiber_block_quote}
    for _, case in ipairs(cases) do
        local conn = pool:get()

        conn.queue:get()
        fiber.create(pool.put, pool, conn)
        local blocked_fiber = fiber.create(case, conn, pool)
        conn.queue:put(true)

        local start_time = fiber.time()
        local is_alive = true

        -- Wait for the blocked fiber to finish,
        -- but no more than "timeout" seconds.
        while fiber.time() - start_time < timeout and is_alive do
            fiber.sleep(0.1)
            is_alive = blocked_fiber:status() ~= 'dead'
        end

        test:ok(is_alive == false, 'fiber is not blocked')
    end

    local non_pool_conn, err = mysql.connect({ host = host, port = port,
        user = user, password = password, db = db })
    if non_pool_conn == nil then error(err) end

    local function make_unusable(conn)
        conn.queue:get()
        conn.usable = false
        conn.queue:put(false)
    end

    local function fiber_block_close(conn)
        local res, err = pcall(conn.close, conn)
        test:ok(res == false and string.find(err, 'Connection is not usable'),
            'close failed')
    end

    non_pool_conn.queue:get()
    fiber.create(make_unusable, non_pool_conn)
    local blocked_fiber = fiber.create(fiber_block_close, non_pool_conn)
    non_pool_conn.queue:put(true)

    local start_time = fiber.time()
    local is_alive = true

    while fiber.time() - start_time < timeout and is_alive do
        fiber.sleep(0.1)
        is_alive = blocked_fiber:status() ~= 'dead'
    end
end

local function test_put_to_wrong_pool(test)
    test:plan(2)

    local pool_cfg = {
        host = host,
        port = port,
        user = user,
        password = password,
        db = db,
        size = 1
    }

    local p1 = mysql.pool_create(pool_cfg)
    local p2 = mysql.pool_create(pool_cfg)

    local c = p1:get()
    local ok, err = pcall(p2.put, p2, c)
    test:is(ok, false, 'Put is failed')
    test:like(tostring(err),
              ('Trying to put connection from pool %s to pool %s'):
              format(p1, p2))
end

-- gh-67: Check that garbage collection of a connection from a connection pool
-- not yields. Yielding in gc is prohibited since Tarantool
-- 2.6.0-138-gd3f1dd720, 2.5.1-105-gc690b3337, 2.4.2-89-g83037df15,
-- 1.10.7-47-g8099cb053. If fiber yield happens in object gc, Tarantool process
-- exits with code 1.
--
-- Gc hook of a connection from a connection pool calls `pool.queue:put(...)`.
-- Fiber `channel:put()` may yield if the channel is full.
-- `channel:put()`/`channel:get()` in mysql driver connection pool is balanced:
-- * the channel capacity is equal to the connection count;
-- * pool create fills the channel with multiple `channel:put()`s
--   all the way through;
-- * `pool:get()` causes single `channel:get()` and creates a connection object
--    with gc hook;
-- * `pool:put()` causes single `channel:put()` and removes gc hook;
-- * gc hook causes single `channel:put()`.
--
-- There are no other cases of `channel:put()`. `pool:put()` and gc hook cannot
-- be executed both in the same time: either a connection is used inside
-- `pool:put()` and won't be garbage collected or a connection is no longer used
-- anywhere else (including `pool:put()`) and it will be garbage collected.
-- So now there are no valid cases when gc hook may yield unless someone messes
-- up with pool queue. Messing up with pool queue anyway breaks a connection
-- pool internal logic, but at least it won't be causing a process exit.
local function test_conn_from_pool_gc_yield(test)
    test:plan(2)

    local p = mysql.pool_create({
        host = host,
        port = port,
        user = user,
        password = password,
        db = db,
        size = 1
    })

    local c = p:get()
    local res = c:ping()
    test:ok(res, 'Connection is ok')
    p.queue:put('killer msg')

    c = nil -- luacheck: no unused
    collectgarbage('collect')
    collectgarbage('collect')

    -- Pool should became unavailable after gc hook finish.
    -- It may be a couple of fiber scheduler cycles.
    local pool_is_usable = true
    for _= 1,10 do
        fiber.yield()

        pool_is_usable = p.usable
        if pool_is_usable == false then
            break
        end
    end

    test:is(pool_is_usable, false, 'Pool is not usable')
end

local test = tap.test('mysql connector')
test:plan(12)

test:test('connection old api', test_old_api, conn)
local pool_conn = p:get()
test:test('connection old api via pool', test_old_api, pool_conn)
test:test('garbage collection', test_gc, p)
test:test('concurrent connections', test_conn_concurrent, p)
test:test('int64', test_mysql_int64, p)
test:test('connection pool', test_connection_pool, p)
test:test('connection reset', test_connection_reset, p)
test:test('test_underlying_conn_closed_during_gc',
          test_underlying_conn_closed_during_gc, p)
test:test('ffi null printing', test_ffi_null_printing, p)
test:test('test_block_fiber_inf', test_block_fiber_inf, p)
test:test('test_put_to_wrong_pool', test_put_to_wrong_pool)
test:test('test_conn_from_pool_gc_yield', test_conn_from_pool_gc_yield)
p:close()

os.exit(test:check() and 0 or 1)
