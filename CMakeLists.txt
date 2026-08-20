# The store: SQLite with a VFS whose pages live in FoundationDB.
# See README.md.
#
# C for the VFS and the programs that exercise it, C++ for the store, because the harness
# and the iceoryx2 dispatch table it generates are C++.
cmake_minimum_required(VERSION 3.22)
project(weft_store C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# clangd reads compile_commands.json for the real include paths and flags. Without it
# clangd guesses, and every FoundationDB and SQLite header looks missing.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Threads REQUIRED)
find_path(FDB_INCLUDE_DIR foundationdb/fdb_c.h REQUIRED)
find_library(FDB_LIBRARY NAMES fdb_c REQUIRED)
find_path(SQLITE_INCLUDE_DIR sqlite3.h REQUIRED)
find_library(SQLITE_LIBRARY NAMES sqlite3 REQUIRED)

add_library(weft_fdb_vfs STATIC fdb_vfs.c)
target_include_directories(weft_fdb_vfs PUBLIC
  ${FDB_INCLUDE_DIR}/foundationdb ${SQLITE_INCLUDE_DIR})
target_compile_definitions(weft_fdb_vfs PUBLIC FDB_API_VERSION=730)
target_link_libraries(weft_fdb_vfs PUBLIC ${FDB_LIBRARY} ${SQLITE_LIBRARY} Threads::Threads)

# One program for each property the store must hold, plus the load harness.
foreach(prog prove_handoff prove_crash prove_big_commit prove_parallel_commit integrity bench_vfs)
  add_executable(${prog} ${prog}.c)
  target_link_libraries(${prog} PRIVATE weft_fdb_vfs)
endforeach()

# TPC-C. Separate from the loop above because it is the only program here that needs threads
# of its own: a terminal is a thread, and the number of them is the axis the benchmark sweeps.
add_executable(tpcc tpcc.c)
target_link_libraries(tpcc PRIVATE weft_fdb_vfs Threads::Threads m)

# The harness, as a subtree. It carries the iceoryx2 C ABI as a dlsym table, the shared
# limits, and the payload types. Nothing here links iceoryx2: the table dlopens it, so the
# store builds on a machine that has never seen it and fails at start rather than at link.
#
# The proof programs are the harness's own and belong to it, not to this build.
set(WEFT_HARNESS_PROOF OFF CACHE BOOL "" FORCE)
add_subdirectory(thirdparty/harness)

# The store. One SQLite database for each avatar, and a thread for each core.
add_executable(store store.cpp)
target_link_libraries(store PRIVATE weft_fdb_vfs weft::harness)
target_compile_options(store PRIVATE -Wall -Wextra)

# The other end of the ring, which measures what the store is for. It opens no database and
# links no VFS, because a caller is not supposed to be able to.
add_executable(store_driver store_driver.cpp)
target_link_libraries(store_driver PRIVATE weft::harness)
target_compile_options(store_driver PRIVATE -Wall -Wextra)
