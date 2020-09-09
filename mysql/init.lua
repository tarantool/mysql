-- init.lua (internal file)

local fiber = require('fiber')
local driver = require('mysql.driver')
local ffi = require('ffi')

local pool_mt
local conn_mt

-- The marker for empty slots in a connection pool.
--
-- When a user puts a connection that is in an unusable state to a
-- pool, we put this marker to a pool's internal connection queue.
--
-- Note: It should not be equal to `nil`, because fiber channel's
-- `get` method returns `nil` when a timeout is reached.
local POOL_EMPTY_SLOT = true

--create a new connection
local function conn_create(mysql_conn)
    local queue = fiber.channel(1)
    queue:put(true)
    local conn = setmetatable({
        usable = true,
        conn = mysql_conn,
        queue = queue,
   }, conn_mt)
    return conn
end

-- get connection from pool
local function conn_get(pool, timeout)
    local mysql_conn = pool.queue:get(timeout)

    -- A timeout was reached.
    if mysql_conn == nil then return nil end

    if mysql_conn == POOL_EMPTY_SLOT then
        local status
        status, mysql_conn = driver.connect(pool.host, pool.port or 0,
                                            pool.user, pool.pass,
                                            pool.db, pool.use_numeric_result)
        if status < 0 then
            error(mysql_conn)
        end
    end

    local conn = conn_create(mysql_conn)
    -- we can use ffi gc to return mysql connection to pool
    conn.__gc_hook = ffi.gc(ffi.new('void *'),
            function(self)
                mysql_conn:close()
                pool.queue:put(POOL_EMPTY_SLOT)
            end)
    return conn
end

local function conn_put(conn)
    local mysqlconn = conn.conn
    ffi.gc(conn.__gc_hook, nil)
    if not conn.queue:get() then
        conn.usable = false
        return POOL_EMPTY_SLOT
    end
    conn.usable = false
    return mysqlconn
end

conn_mt = {
    __index = {
        execute = function(self, sql, ...)
            if not self.usable then
                error('Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                error('Connection is broken')
            end
            local status, datas
            if select('#', ...) > 0 then
                status, datas = self.conn:execute_prepared(sql, ...)
            else
                status, datas = self.conn:execute(sql)
            end
            if status ~= 0 then
                self.queue:put(status > 0)
                error(datas)
            end
            self.queue:put(true)
            return datas, true
        end,
        begin = function(self)
            return self:execute('BEGIN') ~= nil
        end,
        commit = function(self)
            return self:execute('COMMIT') ~= nil
        end,
        rollback = function(self)
            return self:execute('ROLLBACK') ~= nil
        end,
        ping = function(self)
            local status, data, msg = pcall(self.execute, self, 'SELECT 1 AS code')
            return msg and data[1][1].code == 1
        end,
        close = function(self)
            if not self.usable then
                error('Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                error('Connection is broken')
            end
            self.usable = false
            self.conn:close()
            self.queue:put(false)
            return true
        end,
        reset = function(self, user, pass, db)
            if not self.usable then
                error('Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                error('Connection is broken')
            end
            -- If the update of the connection settings fails, we must set
            -- the connection to a "broken" state and throw an error.
            local status = self.conn:reset(user, pass, db)
            if not status then
                self.queue:put(false)
                error('Сonnection settings update failed.')
            end
            self.queue:put(true)
        end,
	quote = function(self, value)
            if not self.usable then
                error('Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                error('Connection is broken')
            end
            local ret = self.conn:quote(value)
            self.queue:put(true)
            return ret
	end
    }
}

-- Create connection pool. Accepts mysql connection params (host, port, user,
-- password, dbname), size.
local function pool_create(opts)
    opts = opts or {}
    opts.size = opts.size or 1
    local queue = fiber.channel(opts.size)

    for i = 1, opts.size do
        local status, conn = driver.connect(opts.host, opts.port or 0,
                                            opts.user, opts.password,
                                            opts.db, opts.use_numeric_result)
        if status < 0 then
            while queue:count() > 0 do
                local mysql_conn = queue:get()
                mysql_conn:close()
            end
            error(conn)
        end
        queue:put(conn)
    end

    return setmetatable({
        -- connection variables
        host        = opts.host,
        port        = opts.port,
        user        = opts.user,
        pass        = opts.password,
        db          = opts.db,
        size        = opts.size,
        use_numeric_result = opts.use_numeric_result,

        -- private variables
        queue       = queue,
        usable      = true
    }, pool_mt)
end

-- Close pool
local function pool_close(self)
    self.usable = false
    for i = 1, self.size do
        local mysql_conn = self.queue:get()
        if mysql_conn ~= POOL_EMPTY_SLOT then
            mysql_conn:close()
        end
    end
    return 1
end

-- Returns connection
local function pool_get(self, opts)
    opts = opts or {}

    if not self.usable then
        error('Pool is not usable')
    end
    local conn = conn_get(self, opts.timeout)

    -- A timeout was reached.
    if conn == nil then return nil end

    conn:reset(self.user, self.pass, self.db)
    return conn
end

-- Free binded connection
local function pool_put(self, conn)
    if conn.usable then
        self.queue:put(conn_put(conn))
    else
        self.queue:put(POOL_EMPTY_SLOT)
    end
end

pool_mt = {
    __index = {
        get = pool_get;
        put = pool_put;
        close = pool_close;
    }
}

-- Create connection. Accepts mysql connection params (host, port, user,
-- password, dbname)
local function connect(opts)
    opts = opts or {}

    local status, mysql_conn = driver.connect(opts.host, opts.port or 0,
                                              opts.user, opts.password,
                                              opts.db, opts.use_numeric_result)
    if status < 0 then
        error(mysql_conn)
    end
    return conn_create(mysql_conn)
end

return {
    connect = connect;
    pool_create = pool_create;
}
