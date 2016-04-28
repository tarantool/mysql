/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include <module.h>

#include <stddef.h>
#include <assert.h>
#include <stdlib.h>
#include <errno.h>

#include <lua.h>
#include <lauxlib.h>

#include <mysql.h>
#include <ma_errmsg.h>

#define TIMEOUT_INFINITY 365 * 86400 * 100.0
static const char mysql_driver_label[] = "__tnt_mysql_driver";

static int
save_pushstring_wrapped(struct lua_State *L)
{
	char *str = (char *)lua_topointer(L, 1);
	lua_pushstring(L, str);
	return 1;
}

static int
safe_pushstring(struct lua_State *L, char *str)
{
	lua_pushcfunction(L, save_pushstring_wrapped);
	lua_pushlightuserdata(L, str);
	return lua_pcall(L, 1, 1, 0);
}

static inline MYSQL *
lua_check_mysqlconn(struct lua_State *L, int index)
{
	MYSQL **conn_p =
		(MYSQL **)luaL_checkudata(L, index, mysql_driver_label);
	if (conn_p == NULL || *conn_p == NULL)
		luaL_error(L, "Driver fatal error (closed connection "
			      "or not a connection)");
	return *conn_p;
}

static inline int
mysql_wait_pending(MYSQL *conn, int status)
{
	int sock = mysql_get_socket(conn);
	int coio_event = 0;
	coio_event |= (status & MYSQL_WAIT_READ ? COIO_READ : 0);
	coio_event |= (status & MYSQL_WAIT_WRITE ? COIO_WRITE : 0);
	int wait_res = coio_wait(sock, coio_event, TIMEOUT_INFINITY);
	return 0 | (wait_res & COIO_READ ? MYSQL_WAIT_READ : 0) |
		(wait_res & COIO_WRITE ? MYSQL_WAIT_WRITE : 0);
}

/* Push connection status and error message to lua stack.
 * Status is -1 if connection is dead or 0 if it is still alive
 */
static int
lua_mysql_push_error(struct lua_State *L, MYSQL *conn)
{
	int err = mysql_errno(conn);
	switch (err) {
	case CR_SERVER_LOST:
	case CR_SERVER_GONE_ERROR:
		lua_pushnumber(L, -1);
		break;
	default:
		lua_pushnumber(L, 0);
	}
	safe_pushstring(L, (char *)mysql_error(conn));
	return 2;
}

/* Push value retrieved from mysql field to lua stack */
static void
lua_mysql_push_value(struct lua_State *L, MYSQL_FIELD *field,
	void *data, unsigned long len)
{
	switch (field->type) {
		case MYSQL_TYPE_TINY:
		case MYSQL_TYPE_SHORT:
		case MYSQL_TYPE_LONG:
		case MYSQL_TYPE_FLOAT:
		case MYSQL_TYPE_INT24:
		case MYSQL_TYPE_DOUBLE: {
			char *data_end = data + len;;
			double v = strtod(data, &data_end);
			lua_pushnumber(L, v);
			break;
		}

		case MYSQL_TYPE_NULL:
			lua_pushnil(L);
			break;

		case MYSQL_TYPE_LONGLONG: {
				long long v = atoll(data);
				if (field->flags & UNSIGNED_FLAG) {
					luaL_pushuint64(L, v);
				} else {
					luaL_pushint64(L, v);
				}
				break;
		}

		/* AS string */
		case MYSQL_TYPE_NEWDECIMAL:
		case MYSQL_TYPE_DECIMAL:
		case MYSQL_TYPE_TIMESTAMP:
		default:
			lua_pushlstring(L, data, len);
			break;
	}
}

/* Push mysql recordset to lua stack */
static int
lua_mysql_fetch_result(struct lua_State *L)
{
	MYSQL *conn = (MYSQL *)lua_topointer(L, 1);
	MYSQL_RES *result = (MYSQL_RES *)lua_topointer(L, 2);

	MYSQL_ROW row;
	int row_idx = 1;
	MYSQL_FIELD *fields = mysql_fetch_fields(result);
	lua_newtable(L);
	do {
		int status = mysql_fetch_row_start(&row, result);
		while (status) {
			status = mysql_wait_pending(conn, status);
			if (fiber_is_cancelled())
				return 0;
			status = mysql_fetch_row_cont(&row, result, status);
		}
		if (!row)
			break;
		lua_pushnumber(L, row_idx);
		lua_newtable(L);
		unsigned long *len = mysql_fetch_lengths(result);
		unsigned col_no;
		for (col_no = 0; col_no < mysql_num_fields(result); ++col_no) {
			if (!row[col_no])
				continue;
			lua_pushstring(L, fields[col_no].name);
			lua_mysql_push_value(L, fields + col_no,
					     row[col_no], len[col_no]);
			lua_settable(L, -3);
		}
		lua_settable(L, -3);
		++row_idx;
	} while (true);
	return 1;
}

/**
 * Execute plain sql script without parameters substitution
 */
static int
lua_mysql_execute(struct lua_State *L)
{
	MYSQL *conn = lua_check_mysqlconn(L, 1);
	size_t len;
	const char *sql = lua_tolstring(L, 2, &len);
	int status, err;

	status = mysql_real_query_start(&err, conn, sql, len);
	while (status) {
		status = mysql_wait_pending(conn, status);
		if (fiber_is_cancelled()) {
			lua_pushnumber(L, -2);
			return 1;
		}
		status = mysql_real_query_cont(&err, conn, status);
	}
	if (err)
		return lua_mysql_push_error(L, conn);

	lua_pushnumber(L, 1);
	int ret_count = 1;

	while (true) {
		MYSQL_RES *res = mysql_use_result(conn);
		if (res) {
			int fail = 0;
			lua_pushcfunction(L, lua_mysql_fetch_result);
			lua_pushlightuserdata(L, conn);
			lua_pushlightuserdata(L, res);
			fail = lua_pcall(L, 2, 1, 0);
			if (mysql_errno(conn)) {
				ret_count = lua_mysql_push_error(L, conn);
				mysql_free_result(res);
				return ret_count;
			}
			mysql_free_result(res);
			if (fiber_is_cancelled()) {
				lua_pushnumber(L, -2);
				return 1;
			}
			if (fail) {
				return lua_error(L);
			}
			++ret_count;
		}
		int next_res, status = mysql_next_result_start(&next_res, conn);
		while (status) {
			status = mysql_wait_pending(conn, status);
			if (fiber_is_cancelled()) {
				lua_pushnumber(L, -2);
				return 1;
			}
			status = mysql_next_result_cont(&next_res, conn, status);
		}
		if (next_res < 0)
			break;
	}
	return ret_count;
}

/*
 * Push row retrieved from prepared statement
 */
static int
lua_mysql_stmt_push_row(struct lua_State *L)
{
	unsigned long col_count = lua_tonumber(L, 1);
	MYSQL_BIND *results = (MYSQL_BIND *)lua_topointer(L, 2);
	MYSQL_FIELD *fields = (MYSQL_FIELD *)lua_topointer(L, 3);

	lua_newtable(L);
	unsigned col_no;
	for (col_no = 0; col_no < col_count; ++col_no) {
		if (*results[col_no].is_null)
			continue;
		lua_pushstring(L, fields[col_no].name);
		lua_mysql_push_value(L, fields + col_no,
				     results[col_no].buffer,
				     *results[col_no].length);
		lua_settable(L, -3);
	}
	return 1;
}

/*
 * Execute sql statement as prepared statement with params
 */
static int
lua_mysql_execute_prepared(struct lua_State *L)
{
	MYSQL *conn = lua_check_mysqlconn(L, 1);
	size_t len;
	const char *sql = lua_tolstring(L, 2, &len);
	int ret_count = 0, fail = 0, error = 0, status;

	MYSQL_STMT *stmt = NULL;
	MYSQL_RES *meta = NULL;
	MYSQL_BIND *param_binds = NULL;
	MYSQL_BIND *result_binds = NULL;
	/* Temporary buffer for input parameters. sizeof(uint64_t) should be
	 * enough to store any number value, any other will be passed as
	 * string from lua */
	uint64_t *values = NULL;

	/* We hope that all should be fine and push 1 (OK) */
	lua_pushnumber(L, 1);
	stmt = mysql_stmt_init(conn);
	if ((error = !stmt))
		goto done;
	status = mysql_stmt_prepare_start(&error, stmt, sql, len);
	while (status) {
		status = mysql_wait_pending(conn, status);
		if (fiber_is_cancelled())
			goto done;
		status = mysql_stmt_prepare_cont(&error, stmt, status);
	}
	if (error)
		goto done;
	/* Alloc space for input parameters */
	unsigned long paramCount = mysql_stmt_param_count(stmt);
	param_binds = (MYSQL_BIND *)calloc(sizeof(*param_binds), paramCount);
	values = (uint64_t *)calloc(sizeof(*values), paramCount);
	/* Setup input bind buffer */
	unsigned param_no;
	for (param_no = 0; param_no < paramCount; ++param_no) {
		if ((unsigned long)lua_gettop(L) <= param_no + 3) {
			param_binds[param_no].buffer_type = MYSQL_TYPE_NULL;
			continue;
		}
		switch (lua_type(L, 3 + param_no)) {
		case LUA_TNIL:
			param_binds[param_no].buffer_type = MYSQL_TYPE_NULL;
			break;
		case LUA_TBOOLEAN:
			param_binds[param_no].buffer_type = MYSQL_TYPE_TINY;
			param_binds[param_no].buffer = values + param_no;
			*(bool *)(values + param_no) =
				lua_toboolean(L, 3 + param_no);
			param_binds[param_no].buffer_length = 1;
			break;
		case LUA_TNUMBER:
			param_binds[param_no].buffer_type = MYSQL_TYPE_DOUBLE;
			param_binds[param_no].buffer = values + param_no;
			*(double *)(values + param_no) =
				lua_tonumber(L, 3 + param_no);
			param_binds[param_no].buffer_length = 8;
			break;
		default:
			param_binds[param_no].buffer_type = MYSQL_TYPE_STRING;
			param_binds[param_no].buffer =
				(char *)lua_tolstring(L, 3 + param_no, &len);
			param_binds[param_no].buffer_length = len;
		}
	}
	mysql_stmt_bind_param(stmt, param_binds);
	status = mysql_stmt_execute_start(&error, stmt);
	while (status) {
		status = mysql_wait_pending(conn, status);
		if (fiber_is_cancelled())
			goto done;
		status = mysql_stmt_execute_cont(&error, stmt, status);
	}
	if (error)
		goto done;
	meta = mysql_stmt_result_metadata(stmt);
	/* Alloc space for output */
	unsigned long col_count = mysql_num_fields(meta);
	result_binds = (MYSQL_BIND *)calloc(sizeof(MYSQL_BIND), col_count);
	MYSQL_FIELD *fields = mysql_fetch_fields(meta);
	unsigned long col_no;
	for (col_no = 0; col_no < col_count; ++col_no) {
		result_binds[col_no].buffer_type = MYSQL_TYPE_STRING;
		result_binds[col_no].buffer = (char *)malloc(fields[col_no].length);
		result_binds[col_no].buffer_length = fields[col_no].length;
		result_binds[col_no].length = (uint64_t *)malloc(sizeof(uint64_t));
		result_binds[col_no].is_null = (my_bool *)malloc(sizeof(my_bool));
	}
	mysql_stmt_bind_result(stmt, result_binds);

	lua_newtable(L);
	unsigned int row_idx = 1;
	while (true) {
		int has_no_row;
		status = mysql_stmt_fetch_start(&has_no_row, stmt);
		while (status) {
			status = mysql_wait_pending(conn, status);
			if (fiber_is_cancelled())
				goto done;
			status = mysql_stmt_fetch_cont(&has_no_row, stmt, status);
		}
		if (has_no_row)
			break;
		lua_pushnumber(L, row_idx);
		lua_pushcfunction(L, lua_mysql_stmt_push_row);
		lua_pushnumber(L, col_count);
		lua_pushlightuserdata(L, result_binds);
		lua_pushlightuserdata(L, fields);
		if ((fail = lua_pcall(L, 3, 1, 0)))
			goto done;
		lua_settable(L, -3);
		++row_idx;
	}
	ret_count = 2;

done:
	if (error)
		ret_count = lua_mysql_push_error(L, conn);
	if (values)
		free(values);
	if (param_binds)
		free(param_binds);
	if (result_binds) {
		unsigned long col_no;
		for (col_no = 0; col_no < col_count; ++col_no) {
			free(result_binds[col_no].buffer);
			free(result_binds[col_no].length);
			free(result_binds[col_no].is_null);
		}
		free(result_binds);
	}
	if (meta)
		mysql_stmt_free_result(stmt);
	if (stmt) {
		my_bool ret;
		status = mysql_stmt_close_start(&ret, stmt);
		while (status) {
			status = mysql_wait_pending(conn, status);
			status = mysql_stmt_close_cont(&ret, stmt, status);
		}
	}
	if (fiber_is_cancelled()) {
		lua_pushnumber(L, -2);
		return 1;
	}
	return fail ? lua_error(L) : ret_count;
}

/**
 * close connection
 */
static int
lua_mysql_close(struct lua_State *L)
{
	MYSQL **conn_p = (MYSQL **)luaL_checkudata(L, 1, mysql_driver_label);
	if (conn_p == NULL || *conn_p == NULL) {
		lua_pushboolean(L, 0);
		return 1;
	}
	mysql_close(*conn_p);
	*conn_p = NULL;
	lua_pushboolean(L, 1);
	return 1;
}

/**
 * collect connection
 */
static int
lua_mysql_gc(struct lua_State *L)
{
	MYSQL **conn_p = (MYSQL **)luaL_checkudata(L, 1, mysql_driver_label);
	if (conn_p && *conn_p)
		mysql_close(*conn_p);
	if (conn_p)
		*conn_p = NULL;
	return 0;
}

static int
lua_mysql_tostring(struct lua_State *L)
{
	MYSQL *conn = lua_check_mysqlconn(L, 1);
	lua_pushfstring(L, "MYSQL: %p", conn);
	return 1;
}

/**
 * quote variable
 */
int
lua_mysql_quote(struct lua_State *L)
{
	MYSQL *mysql = lua_check_mysqlconn(L, 1);
	if (lua_gettop(L) < 2) {
		lua_pushnil(L);
		return 1;
	}

	size_t len;
	const char *s = lua_tolstring(L, -1, &len);
	char *sout = (char*)malloc(len * 2 + 1);
	if (!sout) {
		luaL_error(L, "Can't allocate memory for variable");
	}

	len = mysql_real_escape_string(mysql, sout, s, len);
	lua_pushlstring(L, sout, len);
	free(sout);
	return 1;
}

/**
 * connect to MySQL
 */
static int
lua_mysql_connect(struct lua_State *L)
{
	int status;

	if (lua_gettop(L) < 5) {
		luaL_error(L, "Usage: mysql.connect(host, port, user, "
			   "password, db)");
	}

	const char *host = lua_tostring(L, 1);
	const char *port = lua_tostring(L, 2);
	const char *user = lua_tostring(L, 3);
	const char *pass = lua_tostring(L, 4);
	const char *db = lua_tostring(L, 5);

	MYSQL *conn, *tmp_conn = mysql_init(NULL);
	if (!conn) {
		lua_pushinteger(L, -1);
		int fail = safe_pushstring(L,
					  "Can not allocate memory for connector");
		return fail ? lua_error(L): 2;
	}

	int iport = 0;
	const char *usocket = 0;

	if (host != NULL && strcmp(host, "unix/") == 0) {
		usocket = port;
		host = NULL;
	} else if (port != NULL) {
		iport = atoi(port); /* 0 is ok */
	}

	mysql_options(tmp_conn, MYSQL_OPT_NONBLOCK, 0);
	status = mysql_real_connect_start(&conn, tmp_conn, host, user, pass,
		db, iport, usocket,
		CLIENT_MULTI_STATEMENTS | CLIENT_MULTI_RESULTS);
	while (status) {
		status = mysql_wait_pending(tmp_conn, status);
		if (fiber_is_cancelled()) {
			mysql_close(tmp_conn);
			lua_pushnumber(L, -2);
			return 1;
		}
		status = mysql_real_connect_cont(&conn, tmp_conn, status);
	}

	if (!conn) {
		lua_pushinteger(L, -1);
		int fail = safe_pushstring(L, (char *)mysql_error(tmp_conn));
		mysql_close(tmp_conn);
		return fail ? lua_error(L) : 2;
	}

	lua_pushinteger(L, 1);
	MYSQL **conn_p = (MYSQL **)lua_newuserdata(L, sizeof(MYSQL *));
	*conn_p = conn;
	luaL_getmetatable(L, mysql_driver_label);
	lua_setmetatable(L, -2);

	return 2;
}

static int
lua_mysql_reset(lua_State *L)
{
	MYSQL *conn = lua_check_mysqlconn(L, 1);
	const char *user = lua_tostring(L, 2);
	const char *pass = lua_tostring(L, 3);
	const char *db = lua_tostring(L, 4);
	mysql_change_user(conn, user, pass, db);

	return 0;
}

LUA_API int
luaopen_mysql_driver(lua_State *L)
{
	if (mysql_library_init(0, NULL, NULL))
		luaL_error(L, "Failed to initialize mysql library");

	static const struct luaL_reg methods [] = {
		{"execute_prepared", lua_mysql_execute_prepared},
		{"execute",	lua_mysql_execute},
		{"quote",	lua_mysql_quote},
		{"close",	lua_mysql_close},
		{"reset",	lua_mysql_reset},
		{"__tostring",	lua_mysql_tostring},
		{"__gc",	lua_mysql_gc},
		{NULL, NULL}
	};

	luaL_newmetatable(L, mysql_driver_label);
	lua_pushvalue(L, -1);
	luaL_register(L, NULL, methods);
	lua_setfield(L, -2, "__index");
	lua_pushstring(L, mysql_driver_label);
	lua_setfield(L, -2, "__metatable");
	lua_pop(L, 1);

	lua_newtable(L);
	static const struct luaL_reg meta [] = {
		{"connect", lua_mysql_connect},
		{NULL, NULL}
	};
	luaL_register(L, NULL, meta);
	return 1;
}
