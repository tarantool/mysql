cmake_minimum_required(VERSION 2.8 FATAL_ERROR)

set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake" ${CMAKE_MODULE_PATH})
include(ExternalProject)

find_program(GIT git)

project(mysql C)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

# Find Tarantool
set(TARANTOOL_FIND_REQUIRED ON)
find_package(Tarantool)

# Get git version only if source directory has .git repository, this
# avoids git to search .git repository in parent
# directories.
#
if (EXISTS "${CMAKE_SOURCE_DIR}/.git" AND GIT)
    execute_process (COMMAND ${GIT} describe --long HEAD
	    OUTPUT_VARIABLE TARANTOOL_MYSQL_GIT_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})

    if (NOT ("${TARANTOOL_MYSQL_GIT_VERSION}" STREQUAL "${TARANTOOL_MYSQL_VERSION}"))
	    set(TARANTOOL_MYSQL_VERSION "${TARANTOOL_MYSQL_GIT_VERSION}")
        message(STATUS "Generating VERSION file")
	file(WRITE ${VERSION_FILE} "${TARANTOOL_MYSQL_VERSION}\n")

        message(STATUS "Updating submodules")
        execute_process(COMMAND ${GIT} submodule update --init --recursive)
    endif()
endif()

add_subdirectory(mariadb-connector-c)
#set_target_properties(mariadb-connector-c PROPERTIES COMPILE_FLAGS "-fPIC")
#ExternalProject_Add(mariadb-connector-c
#    SOURCE_DIR "${CMAKE_SOURCE_DIR}/mariadb-connector-c"
#    CMAKE_ARGS -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_C_FLAGS=-fPIC
#        -DCMAKE_CXX_FLAGS=-fPIC -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/lib)

include_directories("${CMAKE_SOURCE_DIR}/mariadb-connector-c/include")
#link_directories(${MYSQL_LIBRARY_DIRS})
#set(MARIADB_LIBRARY "${CMAKE_BINARY_DIR}/lib/lib/mariadb/libmysqlclient.a")

include_directories(${TARANTOOL_INCLUDE_DIRS})

# Set CFLAGS
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -Wall -Wextra")

# Build module
add_subdirectory(mysql)

add_custom_target(check
    COMMAND ${PROJECT_SOURCE_DIR}/test/mysql.test.lua)
