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

# The programs that assert something in-process. These are the default build: each opens a
# database, checks a property and exits, so a plain `cmake --build` produces exactly the set
# a developer can run without arranging anything first.
foreach(prog prove_big_commit integrity)
  add_executable(${prog} ${prog}.c)
  target_link_libraries(${prog} PRIVATE weft_fdb_vfs)
endforeach()

# The fault fixtures, and why they are EXCLUDE_FROM_ALL.
#
# None of these can become an in-process test case, and the reason is the property rather
# than the style. `prove_handoff` needs a *second process*, because what it asserts is that a
# different process with no local file opens the same database — one process cannot witness
# that. `prove_crash` and `prove_parallel_commit` SIGKILL themselves at a chosen commit, so
# linking them into a test runner would kill the runner. Dying is the test.
#
# So they stay separate executables that something else spawns. Keeping them out of the
# default target is the honest encoding of that: they are not built for a developer who wants
# the store, they are built by the stage that spawns them.
#
#   cmake --build BUILD --target fixtures
add_custom_target(fixtures)
foreach(prog prove_handoff prove_crash prove_parallel_commit)
  add_executable(${prog} EXCLUDE_FROM_ALL ${prog}.c)
  target_link_libraries(${prog} PRIVATE weft_fdb_vfs)
  add_dependencies(fixtures ${prog})
endforeach()

# The benchmarks. Out of the default build for a different reason: they assert nothing. A
# benchmark reports a number, and a number with no assertion cannot fail a commit stage, so
# building them by default only slows down the build that does.
#
# `tpcc` is not in the loop because it is the only program here that needs threads of its
# own: a terminal is a thread, and the number of them is the axis the benchmark sweeps.
#
#   cmake --build BUILD --target benchmarks
add_custom_target(benchmarks)
add_executable(bench_vfs EXCLUDE_FROM_ALL bench_vfs.c)
target_link_libraries(bench_vfs PRIVATE weft_fdb_vfs)
add_executable(tpcc EXCLUDE_FROM_ALL tpcc.c)
target_link_libraries(tpcc PRIVATE weft_fdb_vfs Threads::Threads m)
add_dependencies(benchmarks bench_vfs tpcc)

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
