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
        header = "tarantool/tarantool.h"
    },
    MYSQL = {
        header = "mysql/mysql.h",
        library = "libmysqlclient_r"
    }
}
build = {
    type = 'builtin',
    modules = {
        ['mysql.driver'] = {
            sources = 'mysql/driver.c',
            incdirs = {
                "$(TARANTOOL_INCDIR)/tarantool",
                "$(MYSQL_INCDIR)/mysql"
            },
            libdir = "$(MYSQL_LIBDIR)",
            libraries = "mysqlclient_r"
        },
        ['mysql.init'] = 'mysql/init.lua',
    }
}
-- vim: syntax=lua
