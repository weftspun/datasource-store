#!/bin/sh
# One command runs the commit stage.
#
#   ./ci.sh                  every stage
#   ./ci.sh build surface    the named stages, in the order given
#   ./ci.sh --list           what the stages are
#
# The workflow in `.github/workflows/ci.yml` calls this script rather than restating it.
# That is the whole reason the file exists: a pipeline that restates the developer's
# commands drifts from them, and the drift is discovered by a green CI over a broken
# checkout, or the reverse. One script, two callers.
#
# What it does not do is install anything. A missing FoundationDB is a failure here, not a
# skip, because a suite that quietly declines to run reads exactly like a suite that
# passed. `deps` is the first stage and it names what is absent.
#
# Stage exit codes are collected rather than aborted on, so one failure does not hide the
# state of everything after it. The summary at the end is the report, and the script's own
# status is the number of stages that failed.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

BUILD=${BUILD:-build}
FUZZ_BUILD=${FUZZ_BUILD:-build-fuzz}
RUN=${RUN:-${TMPDIR:-/tmp}/weft-ci-run}
export WEFT_FDB_CLUSTER_FILE=${WEFT_FDB_CLUSTER_FILE:-/etc/foundationdb/fdb.cluster}

ALL='deps build surface handoff integrity big-commit parallel-commit crash fuzz spec tla'

if [ "${1:-}" = "--list" ]; then
	echo "$ALL" | tr ' ' '\n'
	exit 0
fi

want=${*:-$ALL}

# The summary is accumulated as text rather than printed as it goes, so the end of a long
# run says what happened without scrolling back through the build output.
summary=''
failed=0
note_result() {
	summary="$summary$1 $2 $3
"
	[ "$2" = FAIL ] && failed=$((failed + 1))
	return 0
}

run_stage() {
	name=$1
	printf '\n========== %s\n' "$name"
	start=$(date +%s)
	rc=0
	"stage_$(echo "$name" | tr - _)" || rc=$?
	elapsed=$(($(date +%s) - start))
	if [ "$rc" = 0 ]; then
		note_result "$name" PASS "${elapsed}s"
	else
		note_result "$name" FAIL "${elapsed}s (exit $rc)"
	fi
}

# --- the stages -------------------------------------------------------------------------

# What must already be here. Each absence is named, and the count is printed even when it
# is zero, so "nothing was missing" and "the check did not run" do not look alike.
stage_deps() {
	missing=0
	for tool in cmake fdbcli; do
		command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool"; missing=$((missing + 1)); }
	done
	[ -f "$WEFT_FDB_CLUSTER_FILE" ] || {
		echo "missing: $WEFT_FDB_CLUSTER_FILE (set WEFT_FDB_CLUSTER_FILE)"
		missing=$((missing + 1))
	}
	if command -v fdbcli >/dev/null 2>&1; then
		if fdbcli --exec 'status minimal' 2>&1 | grep -q 'The database is available'; then
			echo "FoundationDB: available"
		else
			echo "missing: a FoundationDB that answers 'status minimal'"
			missing=$((missing + 1))
		fi
	fi
	echo "absent preconditions: $missing"
	[ "$missing" = 0 ]
}

stage_build() {
	cmake -S . -B "$BUILD" -DCMAKE_BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}
	cmake --build "$BUILD" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
}

# The store calls the FoundationDB surface it says it calls, and every read is
# serializable. Needs no cluster: it reads the built library's undefined symbols.
stage_surface() {
	./check_surface.sh "$BUILD"
}

# A handoff copies nothing. The reader is a different process with no local file, so this
# fails if the VFS ever writes one.
stage_handoff() {
	mkdir -p "$RUN"
	(
		cd "$RUN"
		"$here/$BUILD/prove_handoff" write zone-atlantis.db
		test ! -f zone-atlantis.db || { echo "a local file appeared"; exit 1; }
		"$here/$BUILD/prove_handoff" read zone-atlantis.db
	)
}

# SQLite's own audit of its B-tree, over a database that lives in FoundationDB.
stage_integrity() {
	mkdir -p "$RUN"
	(cd "$RUN" && "$here/$BUILD/integrity" zone-atlantis.db)
}

# The only program that reaches the staging path, where a commit is too large for one
# transaction.
stage_big_commit() {
	mkdir -p "$RUN"
	(cd "$RUN" && "$here/$BUILD/prove_big_commit" big.db 2000 8192)
}

# A grant across two databases lands whole or not at all. The crash points that matter are
# between staging the intents and writing the record, where the group must abort, and
# between the record and moving the heads, where it is already implicitly committed and
# recovery must finish it. Conservation is the oracle, since integrity_check cannot see two
# databases disagreeing.
#
# The points start past setup: a writer seeds the world before the first grant, so a crash
# below about commit 8 leaves nothing to conserve. A run where no point reached a seeded
# world asserted nothing and fails.
stage_parallel_commit() {
	mkdir -p "$RUN"
	cd "$RUN"
	conserved=0
	for point in 8 10 12 14 17 20 25 30; do
		echo "=== crash before write transaction $point ==="
		rc=0
		out=$("$here/$BUILD/prove_parallel_commit" "world-$point.db" "avatar-$point.db" 8 at "$point" 2>&1) || rc=$?
		echo "$out"
		if [ "$rc" = 1 ]; then echo "a grant was partial at $point"; return 1; fi
		case "$out" in *conserved:*) conserved=$((conserved + 1)) ;; esac
	done
	echo "crash points that reached a seeded world: $conserved of 8"
	if [ "$conserved" = 0 ]; then
		echo "every crash point landed in setup, so this stage asserted nothing"
		return 1
	fi
}

# A crash must leave the whole commit or none of it. Walk crash points rather than one,
# since the fault lives at a particular point and a single delay rarely lands inside a
# commit. The full space is the Lean search in `witness/`, too long for a pull request.
stage_crash() {
	mkdir -p "$RUN"
	cd "$RUN"
	seeded=0
	for point in 6 8 10 13 16 21; do
		echo "=== crash before commit $point ==="
		# Exit 2 means the crash point was past the end of the sequence, which is not a
		# fault, so the status is captured rather than left to abort the stage.
		rc=0
		out=$("$here/$BUILD/prove_crash" "crash-$point.db" 400 at "$point" 2>&1) || rc=$?
		echo "$out"
		if [ "$rc" = 1 ]; then echo "torn at crash point $point"; return 1; fi
		case "$out" in *"rows: 0"*) ;; *"rows: "*) seeded=$((seeded + 1)) ;; esac
	done
	echo "crash points that reached a seeded database: $seeded of 6"
	if [ "$seeded" = 0 ]; then
		echo "every crash point landed in setup, so this stage asserted nothing"
		return 1
	fi
}

# `fdb_keys.h` is pure, which is why it was split out: this needs neither FoundationDB nor
# SQLite. Unit-test mode, a short budget for each property. Hunting for a counterexample
# over hours is a separate run.
stage_fuzz() {
	CC=${CC:-clang} CXX=${CXX:-clang++} \
		cmake -S fuzz -B "$FUZZ_BUILD" -DCMAKE_BUILD_TYPE=RelWithDebInfo
	cmake --build "$FUZZ_BUILD" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
	ctest --test-dir "$FUZZ_BUILD" --output-on-failure
}

# The read-ahead window's safety argument. The only stage that checks a proof rather than a
# run, and the only one that needs Lean.
stage_spec() {
	command -v lake >/dev/null 2>&1 || { echo "missing: lake (elan/Lean toolchain)"; return 1; }
	(cd spec && lake build)
}

# The parallel-commit protocol, checked against the spec it claims to be. Three assertions,
# and the third is the one that means something.
#
# One: the committed `WeftParallelCommit.tla` is what `derive.sh` emits from the vendored
# authority. A renaming that anyone can edit afterwards is not a renaming.
#
# Two: TLC checks the derived module — the type invariant, `AckImpliesCommit`, and the four
# temporal properties the authority states about its own record, intents and timestamp cache.
#
# Three: TLC checks the *authority* under the same model, and the two runs must report the
# same state counts. Identical counts is what "the same protocol" reduces to here: the
# renaming cannot have added or removed a reachable state. A run of the derived module alone
# would pass just as happily if the renaming had quietly dropped an action.
stage_tla() {
	command -v java >/dev/null 2>&1 || { echo "missing: java"; return 1; }
	jar=${TLA2TOOLS:-$HOME/.local/lib/tla2tools.jar}
	[ -f "$jar" ] || { echo "missing: $jar (set TLA2TOOLS)"; return 1; }

	./spec/tla/derive.sh --check || return 1

	work=$RUN/tla
	rm -rf "$work"; mkdir -p "$work"
	cp spec/tla/WeftParallelCommit.tla spec/tla/MCWeftParallelCommit.cfg "$work/"
	cp thirdparty/tla/ParallelCommits.tla "$work/"
	# The authority's model is this one with the constants named its way, derived here so
	# the two runs cannot be given different models by accident.
	sed -e 's/DBS/KEYS/' -e 's/RECOVERERS/PREVENTERS/' \
		spec/tla/MCWeftParallelCommit.cfg > "$work/MCParallelCommits.cfg"

	tlc() {
		(cd "$work" && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
			-config "MC$1.cfg" -workers "${JOBS:-4}" "$1" 2>&1)
	}

	authority=$(tlc ParallelCommits)
	derived=$(tlc WeftParallelCommit)

	for out in "$authority" "$derived"; do
		case $out in
			*"Model checking completed. No error has been found."*) ;;
			*) echo "$out" | tail -30; echo "TLC did not complete cleanly"; return 1 ;;
		esac
	done

	# "N states generated, M distinct states found" is the line both runs must agree on.
	a=$(printf '%s' "$authority" | grep -oE '[0-9]+ states generated, [0-9]+ distinct states found' | tail -1)
	d=$(printf '%s' "$derived"   | grep -oE '[0-9]+ states generated, [0-9]+ distinct states found' | tail -1)
	echo "authority: $a"
	echo "derived:   $d"
	[ -n "$a" ] || { echo "no state count from the authority's run"; return 1; }
	if [ "$a" != "$d" ]; then
		echo "the renaming changed the reachable state space"
		return 1
	fi
	echo "the two state spaces are identical, so the renaming added and removed nothing"
}

# --- run --------------------------------------------------------------------------------

for stage in $want; do
	case " $ALL " in
		*" $stage "*) run_stage "$stage" ;;
		*) echo "no such stage: $stage" >&2; exit 2 ;;
	esac
done

printf '\n========== summary\n'
printf '%s' "$summary" | while read -r name result timing; do
	printf '%-18s %-5s %s\n' "$name" "$result" "$timing"
done
printf 'stages failed: %d\n' "$failed"
exit "$failed"
