// The properties the key layout rests on.
//
// `fdb_keys.h` claims that the order of the keys is the order of the numbers. Three
// places in the VFS depend on that and none of them would fail loudly if it stopped being
// true: `edge_number` reads the edge of a range to find the newest shard version and the
// oldest pin, `load_newest_shard` trusts the order it gets, and `drop_unfinished_commit`
// clears a range that begins at a number. A wrong answer there is a read of the wrong
// page, which `PRAGMA integrity_check` cannot see, the same blind spot `prove_crash`
// exists for.
//
// So these are properties over the whole input space rather than examples. Each one is
// stated once, and FuzzTest searches for a counterexample.
//
// SPDX-License-Identifier: Apache-2.0
extern "C" {
#include "fdb_keys.h"
}

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

namespace {

// A database name the layout can carry. The VFS bounds a name at MAX_NAME and builds the
// key with snprintf, so the interesting space is names that are short enough to leave the
// suffix intact.
auto AnyName() {
	return fuzztest::StringOf(fuzztest::PrintableAsciiChar()).WithMaxSize(64);
}

std::string KeyPidx(const std::string& name, uint32_t pgno) {
	uint8_t buf[KEYMAX];
	int n = key_pidx(buf, name.c_str(), pgno);
	return std::string(reinterpret_cast<char*>(buf), static_cast<size_t>(n));
}

std::string KeyDelta(const std::string& name, uint64_t txid, uint32_t pgno) {
	uint8_t buf[KEYMAX];
	int n = key_delta(buf, name.c_str(), txid, pgno);
	return std::string(reinterpret_cast<char*>(buf), static_cast<size_t>(n));
}

std::string KeyShardVersion(const std::string& name, uint64_t as_of) {
	uint8_t buf[KEYMAX];
	int n = key_shard_version(buf, name.c_str(), as_of);
	return std::string(reinterpret_cast<char*>(buf), static_cast<size_t>(n));
}

// ── The encoding round trips ──────────────────────────────────────────────────

void BigEndianRoundTrips(uint64_t v) {
	uint8_t buf[8];
	put_be64(buf, v);
	EXPECT_EQ(get_be64(buf), v);
}
FUZZ_TEST(KeysTest, BigEndianRoundTrips);

// ── The order of the keys is the order of the numbers ─────────────────────────

// The claim itself, for the page index. `edge_number` and every range read depend on it.
void PidxKeysSortLikePageNumbers(const std::string& name, uint32_t a, uint32_t b) {
	std::string ka = KeyPidx(name, a);
	std::string kb = KeyPidx(name, b);
	if (a < b) {
		EXPECT_LT(ka, kb);
	} else if (a > b) {
		EXPECT_GT(ka, kb);
	} else {
		EXPECT_EQ(ka, kb);
	}
}
FUZZ_TEST(KeysTest, PidxKeysSortLikePageNumbers).WithDomains(AnyName(), fuzztest::Arbitrary<uint32_t>(), fuzztest::Arbitrary<uint32_t>());

// A commit's pages sort under their txid, and within a txid by page number. This is what
// makes `DELTA/<txid>/<pgno>` one contiguous range for one commit, which is what
// `drop_unfinished_commit` clears and what a fold reads.
void DeltaKeysSortByTxidThenPage(const std::string& name, uint64_t txid_a, uint32_t pg_a,
                                 uint64_t txid_b, uint32_t pg_b) {
	std::string ka = KeyDelta(name, txid_a, pg_a);
	std::string kb = KeyDelta(name, txid_b, pg_b);
	bool a_first = txid_a < txid_b || (txid_a == txid_b && pg_a < pg_b);
	bool same = txid_a == txid_b && pg_a == pg_b;
	if (same) {
		EXPECT_EQ(ka, kb);
	} else if (a_first) {
		EXPECT_LT(ka, kb);
	} else {
		EXPECT_GT(ka, kb);
	}
}
FUZZ_TEST(KeysTest, DeltaKeysSortByTxidThenPage)
    .WithDomains(AnyName(), fuzztest::Arbitrary<uint64_t>(), fuzztest::Arbitrary<uint32_t>(),
                 fuzztest::Arbitrary<uint64_t>(), fuzztest::Arbitrary<uint32_t>());

// `load_newest_shard` reads the range up to `key_shardn(head + 1)` and takes the last
// row, so a version at or below the head must sort below that bound and one above it must
// not. This is the property that decides which base a read falls through to.
void ShardVersionBoundExcludesExactlyTheVersionsAboveIt(const std::string& name,
                                                        uint64_t as_of, uint64_t head) {
	std::string version = KeyShardVersion(name, as_of);
	std::string bound = KeyShardVersion(name, head == UINT64_MAX ? head : head + 1);
	if (head == UINT64_MAX) return;  // no bound above the maximum to compare against
	if (as_of <= head) {
		EXPECT_LT(version, bound);
	} else {
		EXPECT_GE(version, bound);
	}
}
FUZZ_TEST(KeysTest, ShardVersionBoundExcludesExactlyTheVersionsAboveIt)
    .WithDomains(AnyName(), fuzztest::Arbitrary<uint64_t>(), fuzztest::Arbitrary<uint64_t>());

// ── strinc bounds a prefix exactly ────────────────────────────────────────────

// `key_after` must be strictly above every key carrying the prefix, or a range clear
// leaves rows behind. `drop_unfinished_commit` and `clear_prefix` both rely on it.
void KeyAfterIsAboveEveryKeyWithThePrefix(const std::vector<uint8_t>& prefix,
                                          const std::vector<uint8_t>& tail) {
	if (prefix.empty() || prefix.size() > KEYMAX - 1) return;
	// A prefix of nothing but 0xFF has no successor, and key_after says so by returning
	// zero. A range with an empty end is the caller's problem, not this function's.
	bool all_ff = true;
	for (uint8_t b : prefix) all_ff = all_ff && b == 0xFF;

	uint8_t end[KEYMAX];
	int elen = key_after(end, prefix.data(), static_cast<int>(prefix.size()));
	if (all_ff) {
		EXPECT_EQ(elen, 0);
		return;
	}
	ASSERT_GT(elen, 0);

	std::string bound(reinterpret_cast<char*>(end), static_cast<size_t>(elen));
	std::string key(reinterpret_cast<const char*>(prefix.data()), prefix.size());
	size_t room = KEYMAX - prefix.size();
	key.append(reinterpret_cast<const char*>(tail.data()),
	           tail.size() < room ? tail.size() : room);

	EXPECT_LT(key, bound) << "a key under the prefix sorted at or above the range end";
	EXPECT_GE(key.compare(0, prefix.size(), std::string(reinterpret_cast<const char*>(
	                                             prefix.data()), prefix.size())),
	          0);
}
FUZZ_TEST(KeysTest, KeyAfterIsAboveEveryKeyWithThePrefix);

// key_after may be given the same buffer for input and output, and `clear_prefix` calls
// it that way. Aliasing must not change the answer.
void KeyAfterIsTheSameInPlace(const std::vector<uint8_t>& prefix) {
	if (prefix.empty() || prefix.size() > KEYMAX - 1) return;

	uint8_t apart[KEYMAX], inplace[KEYMAX];
	int a = key_after(apart, prefix.data(), static_cast<int>(prefix.size()));
	memcpy(inplace, prefix.data(), prefix.size());
	int b = key_after(inplace, inplace, static_cast<int>(prefix.size()));

	ASSERT_EQ(a, b);
	EXPECT_EQ(0, memcmp(apart, inplace, static_cast<size_t>(a)));
}
FUZZ_TEST(KeysTest, KeyAfterIsTheSameInPlace);

// ── The transaction record ────────────────────────────────────────────────────

// Recovery sweeps `weft/txn/` and picks records out by shape: a record's key carries an 8
// byte txid where `weft/txn/NEXT` carries a name. If a txid could ever produce the bytes
// of that counter key, the sweep would try to recover the counter.
void TheTxnCounterIsNeverMistakenForARecord(uint64_t txnid) {
	uint8_t status[KEYMAX];
	const int n = key_txn_status(status, txnid);

	uint8_t all[KEYMAX];
	const int prefix = key_txn_all(all);

	// The sweep's test, transcribed: a record key is the prefix, 8 bytes, then "/STATUS".
	ASSERT_GT(n, prefix + 8);
	EXPECT_EQ(0, memcmp(status, all, static_cast<size_t>(prefix)));
	EXPECT_EQ(0, memcmp(status + prefix + 8, "/STATUS", 7));
	EXPECT_EQ(n, prefix + 8 + 7);
}
FUZZ_TEST(KeysTest, TheTxnCounterIsNeverMistakenForARecord);

// A record sorts by its txid, so the sweep reads them in the order they were begun.
void TxnRecordsSortByTxid(uint64_t a, uint64_t b) {
	uint8_t ka[KEYMAX], kb[KEYMAX];
	const int na = key_txn_status(ka, a);
	const int nb = key_txn_status(kb, b);
	std::string sa(reinterpret_cast<char*>(ka), static_cast<size_t>(na));
	std::string sb(reinterpret_cast<char*>(kb), static_cast<size_t>(nb));
	if (a < b) {
		EXPECT_LT(sa, sb);
	} else if (a > b) {
		EXPECT_GT(sa, sb);
	} else {
		EXPECT_EQ(sa, sb);
	}
}
FUZZ_TEST(KeysTest, TxnRecordsSortByTxid);

// A participant row must stay under its own record, or recovery would read one group's
// participants as another's.
void TxnPartsStayUnderTheirRecord(uint64_t txnid, const std::string& name) {
	if (name.size() > 64) return;
	uint8_t part[KEYMAX], prefix[KEYMAX];
	const int n = key_txn_part(part, txnid, name.c_str());
	const int p = key_txn_part_prefix(prefix, txnid);
	ASSERT_GE(n, p);
	EXPECT_EQ(0, memcmp(part, prefix, static_cast<size_t>(p)));
}
FUZZ_TEST(KeysTest, TxnPartsStayUnderTheirRecord)
    .WithDomains(fuzztest::Arbitrary<uint64_t>(), AnyName());

// ── A key stays inside the buffer ─────────────────────────────────────────────

// Every builder writes into a KEYMAX buffer. A name long enough to fill it must not carry
// the suffix past the end, whatever the caller passes.
void EveryBuilderStaysInsideTheBuffer(const std::string& name, uint64_t txid, uint32_t pgno) {
	uint8_t buf[KEYMAX];
	EXPECT_LE(key_pidx(buf, name.c_str(), pgno), KEYMAX);
	EXPECT_LE(key_delta(buf, name.c_str(), txid, pgno), KEYMAX);
	EXPECT_LE(key_shard(buf, name.c_str(), txid, pgno), KEYMAX);
	EXPECT_LE(key_shardn(buf, name.c_str(), txid), KEYMAX);
	EXPECT_LE(key_meta(buf, name.c_str(), "HEAD"), KEYMAX);
	EXPECT_LE(key_prefix(buf, name.c_str(), "PIDX"), KEYMAX);
}
FUZZ_TEST(KeysTest, EveryBuilderStaysInsideTheBuffer)
    .WithDomains(AnyName(), fuzztest::Arbitrary<uint64_t>(), fuzztest::Arbitrary<uint32_t>());

}  // namespace
