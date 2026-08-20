#!/bin/sh
# Form a FoundationDB cluster from whatever machines Fly has started.
#
# The problem this solves. A coordinator list has to be written into a cluster file before
# any process starts, and on Fly a machine's address does not exist until the machine does.
# There is no address to write at build time and no machine to ask at deploy time, so the
# list is discovered at boot instead: every machine resolves the app's internal DNS, which
# returns an AAAA record for each machine in the app, and waits until it sees the expected
# count.
#
# Why waiting for a *count* rather than starting with whoever answers. A cluster file naming
# one coordinator is a valid cluster file. Three machines that each wrote their own would
# form three single-node clusters that never merge, and the deploy would look successful --
# `fly status` reports three healthy machines and every one of them serves reads. That is the
# failure this waits to avoid, and it is why WEFT_FDB_MACHINES is required rather than
# defaulted: a default would silently be wrong on the day someone scales to five.
set -eu

: "${FLY_APP_NAME:?not running on Fly}"
: "${WEFT_FDB_MACHINES:?set WEFT_FDB_MACHINES to the number of machines in this app}"
CLUSTER_DESC=${WEFT_FDB_CLUSTER_DESC:-weft}
CLUSTER_ID=${WEFT_FDB_CLUSTER_ID:?set WEFT_FDB_CLUSTER_ID}
DATA=${WEFT_FDB_DATA:-/data}
PORT=${WEFT_FDB_PORT:-4500}
PROCS=${WEFT_FDB_PROCS:-2}
REDUNDANCY=${WEFT_FDB_REDUNDANCY:-double}
STORAGE=${WEFT_FDB_STORAGE:-ssd-2}

log() { echo "[entrypoint] $*"; }

# This machine's own 6PN address. Fly publishes it as `fly-local-6pn`, which is the only
# name guaranteed to be this machine and not a sibling.
self=$(getent hosts fly-local-6pn | awk '{print $1; exit}')
[ -n "$self" ] || { echo "cannot resolve fly-local-6pn" >&2; exit 1; }
log "self $self  machine ${FLY_MACHINE_ID:-?}  region ${FLY_REGION:-?}"

# Wait for every machine to have an address. 6PN DNS is eventually consistent while a deploy
# rolls, so this polls rather than reading once.
peers=""
waited=0
while [ "$waited" -lt "${WEFT_FDB_DNS_TIMEOUT:-180}" ]; do
	peers=$(getent ahostsv6 "${FLY_APP_NAME}.internal" 2>/dev/null \
		| awk '{print $1}' | sort -u | grep -v '^$' || true)
	n=$(printf '%s\n' "$peers" | grep -c . || true)
	if [ "$n" -ge "$WEFT_FDB_MACHINES" ]; then
		log "found $n of $WEFT_FDB_MACHINES machines"
		break
	fi
	log "waiting for machines: $n of $WEFT_FDB_MACHINES"
	sleep 3
	waited=$((waited + 3))
done
n=$(printf '%s\n' "$peers" | grep -c . || true)
if [ "$n" -lt "$WEFT_FDB_MACHINES" ]; then
	echo "only $n of $WEFT_FDB_MACHINES machines resolved after ${waited}s" >&2
	echo "Refusing to start: a partial coordinator list forms a cluster that looks healthy" >&2
	echo "and is not the cluster that was asked for." >&2
	exit 1
fi

# The coordinator list. Sorted, so every machine writes byte-identical text: FoundationDB
# compares cluster files between processes, and two orderings of the same three addresses
# are two different files to it.
#
# Exactly WEFT_FDB_MACHINES coordinators, taken in sorted order, so scaling past three
# still yields an odd, agreed-upon set rather than everyone who happened to answer.
coords=$(printf '%s\n' "$peers" | sort | head -n "$WEFT_FDB_MACHINES" \
	| sed "s|.*|[&]:$PORT|" | paste -sd, -)
log "coordinators $coords"

mkdir -p /etc/foundationdb "$DATA" /var/log/foundationdb
echo "${CLUSTER_DESC}:${CLUSTER_ID}@${coords}" > /etc/foundationdb/fdb.cluster
chmod 0644 /etc/foundationdb/fdb.cluster
log "cluster file: $(cat /etc/foundationdb/fdb.cluster)"

# One fdbserver per process slot, each on its own port and data directory.
#
# `locality_zoneid` is the machine, not the region. Fault tolerance is counted in zones, so
# telling FoundationDB that three machines are one zone would let it place all replicas of a
# key on one machine and still report itself healthy -- the cluster would claim tolerance it
# does not have, which is the exact failure `qa/consensus.sh` step 3 exists to catch.
conf=/etc/foundationdb/foundationdb.conf
{
	echo "[fdbmonitor]"
	echo "user = root"
	echo "group = root"
	echo ""
	echo "[general]"
	echo "restart_delay = 10"
	echo "cluster_file = /etc/foundationdb/fdb.cluster"
	echo ""
	echo "[fdbserver]"
	echo "command = /usr/sbin/fdbserver"
	echo "datadir = $DATA/\$ID"
	echo "logdir = /var/log/foundationdb"
	echo "public_address = [$self]:\$ID"
	echo "listen_address = public"
	echo "locality_zoneid = ${FLY_MACHINE_ID:-$self}"
	echo "locality_machineid = ${FLY_MACHINE_ID:-$self}"
	echo "locality_dcid = ${FLY_REGION:-unknown}"
	i=0
	while [ "$i" -lt "$PROCS" ]; do
		echo ""
		echo "[fdbserver.$((PORT + i))]"
		i=$((i + 1))
	done
} > "$conf"
log "$PROCS processes from port $PORT"

/usr/lib/foundationdb/fdbmonitor --conffile "$conf" --lockfile /var/run/fdbmonitor.pid &
monitor=$!
log "fdbmonitor pid $monitor"

# Whoever holds the lowest address configures the database, once. A deterministic choice
# rather than a lock, because `configure new` is idempotent in the way that matters: it
# fails on a database that already exists, and the failure is the desired outcome for the
# other two machines.
lowest=$(printf '%s\n' "$peers" | sort | head -1)
if [ "$self" = "$lowest" ]; then
	log "lowest address, so this machine configures the database"
	waited=0
	while [ "$waited" -lt 120 ]; do
		if fdbcli --exec 'status minimal' 2>&1 | grep -q 'The database is available'; then
			log "database already available"
			break
		fi
		out=$(fdbcli --exec "configure new $REDUNDANCY $STORAGE" 2>&1 || true)
		log "configure: $out"
		case "$out" in
			*"Database created"*|*"already exists"*) break ;;
		esac
		sleep 5
		waited=$((waited + 5))
	done
	fdbcli --exec 'status minimal' 2>&1 | sed 's/^/[entrypoint] /' || true
fi

wait "$monitor"
