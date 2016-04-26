cmake_minimum_required(VERSION 2.8 FATAL_ERROR)

project(mysql C)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

# Fetch and patch mariadb-connector-c submodule
execute_process(COMMAND git submodule update --init --recursive)
execute_process(COMMAND cat ../mariadb.patch
		COMMAND patch -p1
	WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/mariadb-connector-c")
add_subdirectory(mariadb-connector-c)
#execute_process(COMMAND cmake -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} .
#	WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/mariadb-connector-c")
#execute_process(COMMAND "make"
#	WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/mariadb-connector-c")
include_directories("${CMAKE_SOURCE_DIR}/mariadb-connector-c/include")
link_directories(${MYSQL_LIBRARY_DIRS})
set(MYSQL_LIBRARIES
	"${CMAKE_BINARY_DIR}/mariadb-connector-c/libmariadb/libmysqlclient.a")

set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake" ${CMAKE_MODULE_PATH})

# Find Tarantool
set(TARANTOOL_FIND_REQUIRED ON)
find_package(Tarantool)
include_directories(${TARANTOOL_INCLUDE_DIRS})


# Set CFLAGS
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -Wall -Wextra")

# Build module
add_subdirectory(mysql)

add_custom_target(check
    COMMAND ${PROJECT_SOURCE_DIR}/test/mysql.test.lua)
