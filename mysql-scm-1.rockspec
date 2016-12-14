package = 'mysql'
version = 'scm-1'
source  = {
    url    = 'git://github.com/tarantool/mysql.git',
    branch = 'master',
}
description = {
    summary  = "MySQL connector for Tarantool",
    homepage = 'https://github.com/tarantool/mysql',
    license  = 'BSD',
}
dependencies = {
    'lua >= 5.1'
}
external_dependencies = {
    TARANTOOL = {
        header = "tarantool/module.h"
    }
}
build = {
    type = 'cmake',
}
-- vim: syntax=lua
