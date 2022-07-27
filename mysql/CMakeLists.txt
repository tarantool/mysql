add_library(driver SHARED driver.c)
add_dependencies(driver mariadbclient)
target_link_libraries(driver mariadbclient)

# Check 'makecontext', 'getcontext', 'setcontext' and 'swapcontext' symbols.

include(CheckLibraryExists)
check_library_exists(c makecontext "" HAVE_UCONTEXT_LIBC)

if (NOT HAVE_UCONTEXT_LIBC)
    # Search for libucontext.
    find_package(PkgConfig)
    if (PKG_CONFIG_FOUND)
        pkg_check_modules(libucontext IMPORTED_TARGET libucontext)
        if (libucontext_FOUND)
            target_link_libraries(driver PkgConfig::libucontext)
        else()
            message(FATAL_ERROR "Missing 'makecontext', 'getcontext', 'setcontext' or 'swapcontext' symbol in libc and no libucontext found.")
        endif()
    else()
        message(FATAL_ERROR "PkgConfig is required to link libucontext.")
    endif()
endif()

set_target_properties(driver PROPERTIES PREFIX "" OUTPUT_NAME "driver")
install(TARGETS driver LIBRARY DESTINATION ${TARANTOOL_INSTALL_LIBDIR}/mysql)
install(FILES init.lua DESTINATION ${TARANTOOL_INSTALL_LUADIR}/mysql)
