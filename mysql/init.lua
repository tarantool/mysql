-- init.lua (internal file)

local fiber = require('fiber')
local driver = require('mysql.driver')
local ffi = require('ffi')

local pool_mt
local conn_mt

-- pool error helper
local function get_error(raise, msg)
    if raise then
        error(msg)
    end
    return nil, msg
end

--create a new connection
local function conn_create(mysql_conn, pool)
    local queue = fiber.channel(1)
    queue:put(true)
    local conn = setmetatable({
        usable = true,
        pool = pool,
        conn = mysql_conn,
        queue = queue,
        -- we can use ffi gc to return mysql connection to pool
        __gc_hook = ffi.gc(ffi.new('void *'),
            function(self)
                mysql_conn:close()
                if not pool.virtual then
                    pool.queue:put(nil)
                end
            end)
    }, conn_mt)

    return conn
end

-- get connection from pool
local function conn_get(pool)
    local mysql_conn = pool.queue:get()
    local status
    local k = mysql_conn
    if mysql_conn == nil then
        status, mysql_conn = driver.connect(pool.host, pool.port or 0,
                                            pool.user, pool.pass, pool.db)
        if status == -1 then
            return get_error(pool.raise, mysql_conn)
        end
        if status == -2 then
            return status
        end
    end
    return conn_create(mysql_conn, pool)
end

local function conn_put(conn)
    local mysqlconn = conn.conn
    ffi.gc(conn.__gc_hook, nil)
    if not conn.queue:get() then
        conn.usable = false
        return nil
    end
    conn.usable = false
    return mysqlconn
end

conn_mt = {
    __index = {
        execute = function(self, sql, ...)
            if not self.usable then
                return get_error(self.pool.raise, 'Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                return get_error(self.pool.raise, 'Connection is broken')
            end
            local status, datas
            if select('#', ...) > 0 then
                status, datas = self.conn:execute_prepared(sql, ...)
            else
                status, datas = self.conn:execute(sql)
            end
            if status ~= 1 then
                self.queue:put(status == 0)
                return get_error(self.pool.raise, datas)
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
            local pool = self.pool
            self.pool = {raise = false}
            local data, msg = self:execute('SELECT 1 AS code')
            self.pool = pool
            return msg and data[1][1].code == 1
        end,
        close = function(self)
            if not self.usable then
                return get_error(self.pool.raise, 'Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                return get_error(self.pool.raise, 'Connection is broken')
            end
            self.usable = false
            self.conn:close()
            self.queue:put(false)
            return true
        end,
        reset = function(self, user, pass, db)
            if not self.usable then
                return get_error(self.pool.raise, 'Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                return get_error(self.pool.raise, 'Connection is broken')
            end
            self.conn:reset(user, pass, db)
            self.queue:put(true)
        end,
	quote = function(self, value)
            if not self.usable then
                return get_error(self.pool.raise, 'Connection is not usable')
            end
            if not self.queue:get() then
                self.queue:put(false)
                return get_error(self.pool.raise, 'Connection is broken')
            end
            local ret = self.conn:quote(value)
            self.queue:put(true)
            return ret
	end
    }
}

-- Create connection pool. Accepts mysql connection params (host, port, user,
-- password, dbname), size and raise flag.
local function pool_create(opts)
    opts = opts or {}
    opts.size = opts.size or 1
    local queue = fiber.channel(opts.size)

    for i = 1, opts.size do
        local status, conn = driver.connect(opts.host, opts.port or 0, opts.user, opts.password, opts.db)
        if status < 0 then
            while queue:count() > 0 do
                local mysql_conn = queue:get()
                mysql_conn:close()
            end
            if status == -1 then
                return get_error(opts.raise, conn)
            else
                return -2
            end
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

        -- private variables
        queue       = queue,
        raise       = opts.raise,
        usable      = true
    }, pool_mt)
end

-- Close pool
local function pool_close(self)
    self.usable = false
    for i = 1, self.size do
        local mysql_conn = self.queue:get()
        if mysql_conn ~= nil then
            mysql_conn:close()
        end
    end
    return 1
end

-- Returns connection
local function pool_get(self)
    if not self.usable then
        return get_error(self.raise, 'Pool is not usable')
    end
    local conn = conn_get(self)
    conn:reset(self.user, self.pass, self.db)
    return conn
end

-- Free binded connection
local function pool_put(self, conn)
    if conn.usable then
        self.queue:put(conn_put(conn))
    else
        self.queue:put(nil)
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
-- password, dbname) separatelly or in one string and raise flag.
local function connect(opts)
    opts = opts or {}
    local pool = {virtual = true, raise = opts.raise}

    local status, mysql_conn = driver.connect(opts.host, opts.port or 0, opts.user, opts.password, opts.db)
    if status == -1 then
        return get_error(pool.raise, mysql_conn)
    end
    if status == -2 then
        return -2
    end
    return conn_create(mysql_conn, pool)
end

return {
    connect = connect;
    pool_create = pool_create;
}
