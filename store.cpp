// The store: one SQLite database for each avatar, and a thread for each core.
//
//   store [shards]
//
// A caller never opens a database. It names an avatar on the ring and this process owns
// every handle, which is what keeps one owner and one fence for each database. See
// `weft/store.hpp` for the contract and `fdb_vfs.c` for what a handle actually is.
//
// Why a thread for each core, and why that is the whole point. A commit is one FoundationDB
// transaction, about 1 ms, and SQLite waits inside `xSync` while it happens. So one thread
// committing serially is bounded by that round trip however small the payload is. The depth
// comes from the number of avatars committing at once: many threads, each blocked in its own
// commit, are many transactions in flight through the one FoundationDB network thread the
// client process has. `docs/logbook/store.md` measured that as 44 times, and this loop
// is the thing that was missing to reach it.
//
// Why a service for each shard. Publish and subscribe is a broadcast, so every subscriber on
// one service receives every message. One service shared by every thread would hand each
// request to all of them. A shard is a service instead, an avatar belongs to exactly one, and
// so the handle cache below needs no lock: the thread subscribed to a shard is the only
// thread that will ever touch those avatars.
//
// SPDX-License-Identifier: Apache-2.0
#include "iox2_api.h"
#include "weft/bus.hpp"
#include "weft/store.hpp"

#include <sqlite3.h>

#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

extern "C" {
int weft_fdb_start(const char* cluster_file);
void weft_fdb_stop(void);
int weft_vfs_register(int make_default);
int weft_compact_due(sqlite3* db);
}

namespace {

std::atomic<bool> g_running {true};

// How many commits this process has completed, so the claim the store exists to test —
// that commits per second rise with avatar count — can be read off a running store.
std::atomic<std::uint64_t> g_commits {0};

// One avatar's database, held open for as long as the caller owns it.
//
// The handle is what carries the fence. `fdb_vfs.c` raises the fence when the file is
// opened, so closing and reopening between commits would raise it again and cost a round
// trip to learn nothing. Holding the handle is what makes an avatar an owner rather than a
// visitor.
struct Avatar {
    sqlite3* db = nullptr;
};

int exec(sqlite3* db, const char* sql) {
    char* err = nullptr;
    const int rc = sqlite3_exec(db, sql, nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        std::fprintf(stderr, "store: %s -> %s\n", sql, err ? err : "?");
    }
    sqlite3_free(err);
    return rc;
}

// Open one avatar's database over the VFS.
//
// The two pragmas are the caller contract `fdb_vfs.c` states, and neither is a tuning knob.
// The journal must stay in memory because the commit is already atomic, and exclusive
// locking stops SQLite re-reading page 1 to check the change counter at the start of every
// read transaction, which over a database on the network is a round trip for every query.
sqlite3* open_avatar(std::uint64_t avatar) {
    char name[64];
    std::snprintf(name, sizeof name, "avatar-%" PRIu64 ".db", avatar);

    sqlite3* db = nullptr;
    const int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    if (sqlite3_open_v2(name, &db, flags, "weft_fdb") != SQLITE_OK) {
        std::fprintf(stderr, "store: open %s: %s\n", name,
                     db ? sqlite3_errmsg(db) : "no handle");
        sqlite3_close(db);
        return nullptr;
    }
    if (exec(db, "PRAGMA journal_mode=MEMORY") != SQLITE_OK
        || exec(db, "PRAGMA locking_mode=EXCLUSIVE") != SQLITE_OK) {
        sqlite3_close(db);
        return nullptr;
    }
    return db;
}

// One CBOR head: major type and its length or value, big-endian per RFC 8949.
void cbor_head(std::string& out, std::uint8_t major, std::uint64_t v) {
    const std::uint8_t m = static_cast<std::uint8_t>(major << 5);
    if (v < 24) {
        out.push_back(static_cast<char>(m | v));
    } else if (v <= 0xff) {
        out.push_back(static_cast<char>(m | 24));
        out.push_back(static_cast<char>(v));
    } else if (v <= 0xffff) {
        out.push_back(static_cast<char>(m | 25));
        out.push_back(static_cast<char>(v >> 8));
        out.push_back(static_cast<char>(v));
    } else {
        out.push_back(static_cast<char>(m | 26));
        for (int s = 24; s >= 0; s -= 8) out.push_back(static_cast<char>(v >> s));
    }
}

// Run one statement and put the rows in the reply as CBOR: an indefinite-length array of
// rows, each row a definite array of text strings, NULL as null. Truncation drops whole
// rows so the document stays well formed; the caller sees fewer rows, never a torn one.
int read_rows(sqlite3* db, const char* sql, std::uint8_t* body, std::uint32_t* length) {
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK) {
        return SQLITE_ERROR;
    }

    std::string out;
    out.push_back(static_cast<char>(0x9f));
    while (sqlite3_step(st) == SQLITE_ROW) {
        const int columns = sqlite3_column_count(st);
        std::string row;
        cbor_head(row, 4, static_cast<std::uint64_t>(columns));
        for (int i = 0; i < columns; ++i) {
            const unsigned char* text = sqlite3_column_text(st, i);
            if (!text) {
                row.push_back(static_cast<char>(0xf6));
                continue;
            }
            const std::size_t n = static_cast<std::size_t>(sqlite3_column_bytes(st, i));
            cbor_head(row, 3, n);
            row.append(reinterpret_cast<const char*>(text), n);
        }
        if (out.size() + row.size() + 1 > weft::STORE_BODY_BYTES) break;
        out += row;
    }
    out.push_back(static_cast<char>(0xff));
    sqlite3_finalize(st);

    std::memcpy(body, out.data(), out.size());
    *length = static_cast<std::uint32_t>(out.size());
    return SQLITE_OK;
}

// Answer one request. The reply is filled in whatever happens, because a caller waiting on a
// request_id that never comes back cannot tell a lost message from a slow one.
void serve(std::unordered_map<std::uint64_t, Avatar>& avatars, const weft::StoreRequest& in,
           weft::StoreReply& out) {
    out.request_id = in.request_id;
    out.avatar = in.avatar;
    out.length = 0;
    out.code = SQLITE_OK;

    // A body is text, and it arrives with its length rather than a terminator.
    char sql[weft::STORE_BODY_BYTES];
    const std::uint32_t n = in.length < weft::STORE_BODY_BYTES ? in.length
                                                               : weft::STORE_BODY_BYTES - 1;
    std::memcpy(sql, in.body, n);
    sql[n] = '\0';

    switch (in.op) {
    case weft::STORE_OPEN: {
        if (avatars.count(in.avatar)) return; // already ours, and the fence is already held
        sqlite3* db = open_avatar(in.avatar);
        if (!db) {
            out.code = SQLITE_CANTOPEN;
            return;
        }
        avatars.emplace(in.avatar, Avatar {db});
        return;
    }
    case weft::STORE_READ: {
        auto it = avatars.find(in.avatar);
        if (it == avatars.end()) {
            out.code = SQLITE_MISUSE; // read before open, which is the caller's bug
            return;
        }
        out.code = read_rows(it->second.db, sql, out.body, &out.length);
        return;
    }
    case weft::STORE_COMMIT: {
        auto it = avatars.find(in.avatar);
        if (it == avatars.end()) {
            out.code = SQLITE_MISUSE;
            return;
        }
        // One statement, one SQLite commit, one FoundationDB transaction. The thread blocks
        // here inside xSync, which is exactly what makes it a commit in flight rather than
        // a queued one, and why the loop wants a thread for each core.
        out.code = exec(it->second.db, sql);
        if (out.code == SQLITE_OK) {
            g_commits.fetch_add(1, std::memory_order_relaxed);
        }
        return;
    }
    case weft::STORE_CLOSE: {
        auto it = avatars.find(in.avatar);
        if (it == avatars.end()) return;
        sqlite3_close(it->second.db); // xClose flushes, so this is where a last commit lands
        avatars.erase(it);
        return;
    }
    default:
        out.code = SQLITE_MISUSE;
        return;
    }
}

// Open one pub/sub service by name, with the payload details both ends must agree on.
// iceoryx2 rejects the second port when they differ, and that check is what stops one
// process reading another process's layout as its own.
iox2_port_factory_pub_sub_h open_service(iox2_node_h& node, const char* service_name,
                                         const char* type_name, std::size_t size,
                                         std::size_t align) {
    iox2_service_name_h name = nullptr;
    if (iox2_service_name_new(nullptr, service_name, std::strlen(service_name), &name)
        != IOX2_OK) {
        std::fprintf(stderr, "store: no service name %s\n", service_name);
        return nullptr;
    }

    auto builder = iox2_service_builder_pub_sub(
        iox2_node_service_builder(&node, nullptr, iox2_cast_service_name_ptr(name)));

    if (iox2_service_builder_pub_sub_set_payload_type_details(
            &builder, iox2_type_variant_e_FIXED_SIZE, type_name, std::strlen(type_name), size,
            align)
        != IOX2_OK) {
        std::fprintf(stderr, "store: type details rejected for %s\n", service_name);
        iox2_service_name_drop(name);
        return nullptr;
    }

    iox2_port_factory_pub_sub_h service = nullptr;
    if (iox2_service_builder_pub_sub_open_or_create(builder, nullptr, &service) != IOX2_OK) {
        std::fprintf(stderr, "store: no service %s\n", service_name);
        iox2_service_name_drop(name);
        return nullptr;
    }
    iox2_service_name_drop(name);
    return service;
}

// One shard: its own node, its own ports, and its own avatars. Nothing here is shared with
// another shard, so nothing here is locked.
void shard_loop(std::uint32_t shard) {
    char request_name[128];
    char reply_name[128];
    weft::store_service_name(request_name, sizeof request_name, weft::STORE_REQUEST_SERVICE,
                             shard);
    weft::store_service_name(reply_name, sizeof reply_name, weft::STORE_REPLY_SERVICE, shard);

    iox2_node_h node = nullptr;
    if (iox2_node_builder_create(iox2_node_builder_new(nullptr), nullptr,
                                 iox2_service_type_e_IPC, &node)
        != IOX2_OK) {
        std::fprintf(stderr, "store: shard %u has no node\n", shard);
        return;
    }

    iox2_port_factory_pub_sub_h requests =
        open_service(node, request_name, weft::STORE_REQUEST_TYPE, sizeof(weft::StoreRequest),
                     alignof(weft::StoreRequest));
    iox2_port_factory_pub_sub_h replies =
        open_service(node, reply_name, weft::STORE_REPLY_TYPE, sizeof(weft::StoreReply),
                     alignof(weft::StoreReply));
    if (!requests || !replies) {
        iox2_node_drop(node);
        return;
    }

    iox2_subscriber_h subscriber = nullptr;
    if (iox2_port_factory_subscriber_builder_create(
            iox2_port_factory_pub_sub_subscriber_builder(&requests, nullptr), nullptr,
            &subscriber)
        != IOX2_OK) {
        std::fprintf(stderr, "store: shard %u has no subscriber\n", shard);
        iox2_node_drop(node);
        return;
    }

    iox2_publisher_h publisher = nullptr;
    if (iox2_port_factory_publisher_builder_create(
            iox2_port_factory_pub_sub_publisher_builder(&replies, nullptr), nullptr,
            &publisher)
        != IOX2_OK) {
        std::fprintf(stderr, "store: shard %u has no publisher\n", shard);
        iox2_node_drop(node);
        return;
    }

    std::unordered_map<std::uint64_t, Avatar> avatars;

    while (g_running.load(std::memory_order_relaxed)) {
        iox2_sample_h sample = nullptr;
        if (iox2_subscriber_receive(&subscriber, nullptr, &sample) != IOX2_OK) {
            std::fprintf(stderr, "store: shard %u receive failed\n", shard);
            break;
        }
        if (sample == nullptr) {
            // Nothing waiting, so this is the moment to pay any fold a commit noticed was
            // owed. Doing it here rather than inside a commit is the whole point: the
            // thread is already idle, and no caller is waiting on it.
            for (auto& [id, avatar] : avatars) {
                (void)id;
                if (weft_compact_due(avatar.db) != SQLITE_OK) break;
            }
            // Sleeping here costs latency and not throughput, because a shard with work
            // never reaches this branch.
            (void)iox2_node_wait(&node, 0, 200 * 1000);
            continue;
        }

        const void* payload = nullptr;
        std::size_t elements = 0;
        iox2_sample_payload(&sample, &payload, &elements);

        weft::StoreRequest in {};
        std::memcpy(&in, payload, sizeof(in));
        iox2_sample_drop(sample);

        iox2_sample_mut_h loan = nullptr;
        if (iox2_publisher_loan_slice_uninit(&publisher, nullptr, &loan, 1) != IOX2_OK) {
            std::fprintf(stderr, "store: shard %u has no loan\n", shard);
            break;
        }
        void* reply_payload = nullptr;
        iox2_sample_mut_payload_mut(&loan, &reply_payload, &elements);

        auto* out = static_cast<weft::StoreReply*>(reply_payload);
        serve(avatars, in, *out);

        if (iox2_sample_mut_send(loan, nullptr) != IOX2_OK) {
            std::fprintf(stderr, "store: shard %u send failed\n", shard);
            break;
        }
    }

    for (auto& [id, avatar] : avatars) {
        (void)id;
        sqlite3_close(avatar.db);
    }

    iox2_publisher_drop(publisher);
    iox2_subscriber_drop(subscriber);
    iox2_port_factory_pub_sub_drop(replies);
    iox2_port_factory_pub_sub_drop(requests);
    iox2_node_drop(node);
}

} // namespace

int main(int argc, char** argv) {
    // A thread for each core by default, since that is the shape the harness is for. The
    // count is also the shard count, because a shard is what a thread owns.
    unsigned shards = std::thread::hardware_concurrency();
    if (argc > 1) shards = static_cast<unsigned>(std::atoi(argv[1]));
    if (shards == 0) shards = 1;

    if (!weft::load_bus()) {
        return 1;
    }
    iox2_set_log_level_from_env_or(iox2_log_level_e_ERROR);

    if (const int err = weft_fdb_start(std::getenv("WEFT_FDB_CLUSTER_FILE"))) {
        std::fprintf(stderr, "store: FoundationDB did not start: %d\n", err);
        return 1;
    }
    // Not the default VFS. Every database this process opens names it, and nothing else
    // should get it by accident.
    weft_vfs_register(0);

    std::printf("store: %u shards, one database for each avatar\n", shards);
    std::fflush(stdout);

    std::vector<std::thread> threads;
    threads.reserve(shards);
    for (std::uint32_t shard = 0; shard < shards; ++shard) {
        threads.emplace_back(shard_loop, shard);
    }
    for (auto& thread : threads) {
        thread.join();
    }

    std::printf("store: %" PRIu64 " commits\n", g_commits.load());
    weft_fdb_stop();
    return 0;
}
