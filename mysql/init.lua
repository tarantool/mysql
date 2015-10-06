-- sql.lua (internal file)

local fiber = require('fiber')
local driver = require('mysql.driver')

local conn_mt

-- mysql.connect({host = host, port = port, user = user,
--               password = password, db = db, raise = false })
-- @param debug if option raise set in 'false' and an error will be happened
--   the function will return 'nil' as the first variable and text of error as
--   the second value.
-- @return connector to database or throw error
local function connect(opts)
    opts = opts or {}

    local s, c = driver.connect(opts.host, opts.port, opts.user,
        opts.password, opts.db)
    if s == nil then
        if opts.raise then
            error(c)
        end
        return nil, c
    end

    return setmetatable({
        driver = c,

        -- connection variables
        host        = opts.host,
        port        = opts.port,
        user        = opts.user,
        password    = opts.password,
        db          = opts.db,

        -- private variables
        queue       = {},
        processing  = false,

        -- throw exception if error
        raise       = opts.raise
    }, conn_mt)
end

--
-- Close connection
--
local function close(self)
    return self.driver:close()
end

-- example:
-- local tuples, arows = db:execute(sql, args)
--   tuples - a table of tuples (tables)
--   arows  - count of affected rows

-- the method throws exception by default.
-- user can change the behaviour by set 'connection.raise'
-- attribute to 'false'
-- in the case it will return negative arows if error and
-- txtst will contain text of error
local function execute(self, sql, ...)
    -- waits until connection will be free
    while self.processing do
        self.queue[ fiber.id() ] = fiber.channel()
        self.queue[ fiber.id() ]:get()
        self.queue[ fiber.id() ] = nil
    end
    self.processing = true
    local status, tuples, nrows = pcall(self.driver.execute, self.driver, sql, ...)
    self.processing = false
    if not status then
        if self.raise then
            error(tuples)
        end
        return nil, tuples
    end

    -- wakeup one waiter
    for fid, ch in pairs(self.queue) do
        ch:put(true, 0)
        self.queue[ fid ] = nil
        break
    end
    return tuples, nrows
end

-- pings database
-- returns true if success. doesn't throw any errors
local function ping(self)
    local raise = self.raise
    self.raise = false
    local res = self:execute('SELECT 1 AS code')
    self.raise = raise
    return res ~= nil and res[1].code == 1
end

-- begin transaction
local function begin(self)
    return self:execute('BEGIN') ~= nil
end

-- commit transaction
local function commit(self)
    return self:execute('COMMIT') ~= nil
end

-- rollback transaction
local function rollback(self)
    return self:execute('ROLLBACK') ~= nil
end

conn_mt = {
    __index = {
        close = close;
        execute = execute;
        ping = ping;
        begin = begin;
        rollback = rollback;
        commit = commit;
    }
}

return {
    connect = connect;
}
