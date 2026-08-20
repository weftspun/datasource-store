# The fuzz tests, over the properties in fdb_keys.h.
#
# Separate from the root build because this is the one part of the tree that needs C++,
# a network fetch, and a recent Clang. The root build stays a C build that works without
# any of them.
#
#   cmake -S fuzz -B build-fuzz -DCMAKE_BUILD_TYPE=RelWithDebInfo
#   cmake --build build-fuzz -j
#   ctest --test-dir build-fuzz --output-on-failure
#
# That runs each property against random inputs for a short budget, which is what CI does
# on every pull request. To hunt instead of check, build with Clang and run one property
# for as long as it is worth:
#
#   ./build-fuzz/keys_test --fuzz=KeysTest.PidxKeysSortLikePageNumbers
#
# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.19)
project(weft_store_fuzz CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# Pinned, not floating. A fuzz run that changes because the framework moved underneath it
# cannot be compared with the run before it.
FetchContent_Declare(
  fuzztest
  GIT_REPOSITORY https://github.com/google/fuzztest.git
  GIT_TAG 2026-06-29
)
FetchContent_MakeAvailable(fuzztest)

enable_testing()
include(GoogleTest)

fuzztest_setup_fuzzing_flags()

add_executable(keys_test keys_test.cc)
# The header under test is in the parent directory, and it is all this needs: no
# FoundationDB, no SQLite, no I/O.
target_include_directories(keys_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_compile_options(keys_test PRIVATE -Wall -Wextra)
link_fuzztest(keys_test)
gtest_discover_tests(keys_test)
