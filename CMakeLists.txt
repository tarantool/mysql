cmake_minimum_required(VERSION 2.8 FATAL_ERROR)

include(ExternalProject)

project(mysql C)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

# Fetch and patch mariadb-connector-c submodule
execute_process(COMMAND git submodule update --init --recursive
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
ExternalProject_Add(mariadb-connector-c
    SOURCE_DIR "${CMAKE_SOURCE_DIR}/mariadb-connector-c"
    CMAKE_ARGS -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_C_FLAGS=-fPIC
        -DCMAKE_CXX_FLAGS=-fPIC -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/lib)

include_directories("${CMAKE_BINARY_DIR}/lib/include/mariadb")
link_directories(${MYSQL_LIBRARY_DIRS})
set(MARIADB_LIBRARY "${CMAKE_BINARY_DIR}/lib/lib/mariadb/libmysqlclient.a")

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
