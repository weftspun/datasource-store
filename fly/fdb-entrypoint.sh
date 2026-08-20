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
# A TLS cluster's coordinator addresses carry a `:tls` suffix, and it is part of the address
# rather than decoration: a process reading an address without it speaks plaintext to a peer
# that will not, and the connection fails with no indication that TLS was the reason.
sfx=""
[ -n "${FDB_TLS_CERT_B64:-}" ] && sfx=":tls"
coords=$(printf '%s\n' "$peers" | sort | head -n "$WEFT_FDB_MACHINES" \
	| sed "s|.*|[&]:$PORT$sfx|" | paste -sd, -)
log "coordinators $coords"

mkdir -p /etc/foundationdb "$DATA" /var/log/foundationdb

# Discard the data directory and start empty.
#
# This exists because there is no in-place path from a plaintext cluster to a TLS one.
# A coordinator's address is part of its identity, `:tls` is part of the address, and the
# coordinated state on disk was written under the old one -- so the processes come up, speak
# TLS to each other correctly, and never reach a quorum, because the quorum they are looking
# for is recorded at addresses that no longer exist. `status` reports "Could not communicate
# with a quorum of coordination servers" and every other signal looks healthy.
#
# So enabling TLS on a running cluster means recreating it. That is a real cost and it is
# written here rather than rediscovered: decide TLS before there is data worth keeping, or
# plan a backup and restore around the change.
if [ "${WEFT_FDB_RESET:-0}" = 1 ]; then
	log "WEFT_FDB_RESET=1: discarding everything under $DATA"
	rm -rf "${DATA:?}"/* 2>/dev/null || true
	log "$DATA now holds $(ls -A "$DATA" 2>/dev/null | wc -l) entries"
fi

# TLS, if the material was given. One wildcard certificate is presented by every process and
# verified by every peer against the same subject, which is what makes one certificate enough
# for a whole cluster: FoundationDB pins on the certificate's subject rather than matching a
# hostname against the address it connected to. On 6PN there is no hostname to match anyway,
# since peers reach each other at IPv6 literals.
#
# The material arrives base64-encoded. A PEM is multi-line, and a multi-line value survives
# neither a secrets store nor a shell round-trip reliably enough to be trusted with the thing
# standing between this database and anyone who can route to it.
tls=0
# Each machine carries its own certificate, chosen by the last four characters of its NIC.
#
# Not the first four: every Fly NIC begins `de:ad:` -- their OUI -- so a prefix names `dead`
# on every machine in the fleet and identifies nothing. The last two octets differ.
#
# Fly secrets are app-wide rather than per-machine, so all three pairs are present on all
# three machines and each takes the one addressed to it. A machine that finds no pair for its
# own NIC stops, because the alternative is falling back to somebody else's identity.
nic=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tr 'A-Z' 'a-z')
nic=$(printf '%s' "$nic" | tail -c 4)   # last four, and -c 4 not -c 5: the trailing newline is already gone
if [ -n "${nic:-}" ] && [ -z "${FDB_TLS_CERT_B64:-}" ]; then
	eval "FDB_TLS_CERT_B64=\${FDB_TLS_CERT_${nic}_B64:-}"
	eval "FDB_TLS_KEY_B64=\${FDB_TLS_KEY_${nic}_B64:-}"
	if [ -n "${FDB_TLS_CERT_B64:-}" ]; then
		log "TLS identity fdb-$nic (from NIC), chosen from the per-machine secrets"
	elif [ -n "${FDB_TLS_CA_B64:-}" ]; then
		echo "a CA was given but no certificate for this machine's NIC ($nic)" >&2
		echo "Expected FDB_TLS_CERT_${nic}_B64. Refusing to start rather than borrow another" >&2
		echo "machine's identity, which would make peer verification meaningless." >&2
		exit 1
	fi
fi

if [ -n "${FDB_TLS_CERT_B64:-}" ]; then
	[ -n "${FDB_TLS_KEY_B64:-}" ] || { echo "FDB_TLS_CERT_B64 without FDB_TLS_KEY_B64" >&2; exit 1; }
	[ -n "${FDB_TLS_CA_B64:-}" ]  || { echo "FDB_TLS_CERT_B64 without FDB_TLS_CA_B64" >&2; exit 1; }
	mkdir -p /etc/foundationdb/tls
	printf '%s' "$FDB_TLS_CERT_B64" | base64 -d > /etc/foundationdb/tls/cert.pem
	printf '%s' "$FDB_TLS_KEY_B64"  | base64 -d > /etc/foundationdb/tls/key.pem
	printf '%s' "$FDB_TLS_CA_B64"   | base64 -d > /etc/foundationdb/tls/ca.pem
	# Complete the chain to a self-signed root, and why this is not optional.
	#
	# Let's Encrypt hands out an issuer chain that ends at a *cross-signed* root -- here
	# `ISRG Root X2` as signed by `ISRG Root X1` -- and not at a self-signed one. OpenSSL's
	# `verify` accepts that, because `-CAfile` treats every certificate in the file as a
	# trust anchor, so a check built on it reports OK. FoundationDB does not: it wants a path
	# to a self-signed root, and without one every handshake fails with
	# `TLSPolicyFailure Reason="preverification"`.
	#
	# The failure mode is the expensive part. The processes start, report healthy, speak TLS
	# to each other perfectly, and never form a quorum -- `status` says only "Could not
	# communicate with a quorum of coordination servers", which reads like a networking or
	# coordinator problem and not like a certificate one.
	#
	# Only the roots that actually anchor this chain are appended, rather than the system
	# bundle. Appending the bundle would work and would quietly widen the trusted issuer set
	# from one CA to every public CA, leaving `S.CN` as the only thing between this cluster
	# and anyone who can get a certificate for the name.
	# The CA file is used exactly as given. Nothing is appended and nothing is truncated.
	#
	# An earlier version completed the chain from the system trust store, written when the
	# certificate came from a public CA whose chain ends at a cross-signed root. Against a
	# private CA that would have thrown away the only certificate that matters and trusted the
	# public roots instead: the cluster would accept anything a public CA had ever issued for
	# the pinned name, and reject the certificate it was actually given.
	#
	# A private root needs none of it. It is self-signed, so it is already an anchor -- which
	# is the property Let's Encrypt's cross-signed chain could not provide and the reason
	# every handshake failed at `preverification`.

	# A self-signed certificate is one whose subject is its own issuer. If none survived the
	# step above, the chain has no anchor and the handshake will fail on every peer -- so it
	# fails here instead, where the message can say so.
	anchors=0
	csplit -sz -f /tmp/ca- -b '%02d.pem' /etc/foundationdb/tls/ca.pem '/BEGIN CERTIFICATE/' '{*}' 2>/dev/null || true
	for c in /tmp/ca-*.pem; do
		[ -f "$c" ] || continue
		sub=$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject=//')
		iss=$(openssl x509 -in "$c" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
		[ -n "$sub" ] && [ "$sub" = "$iss" ] && anchors=$((anchors + 1))
	done
	rm -f /tmp/ca-*.pem
	log "TLS ca.pem: $anchors self-signed anchor(s)"
	if [ "$anchors" = 0 ]; then
		echo "the CA file contains no self-signed root" >&2
		echo "FoundationDB needs a path to a self-signed anchor. `openssl verify -CAfile` will" >&2
		echo "accept a cross-signed chain and FoundationDB will not, so that check does not" >&2
		echo "cover this. Every peer handshake would fail with Reason=preverification." >&2
		exit 1
	fi

	chmod 0600 /etc/foundationdb/tls/key.pem
	chmod 0644 /etc/foundationdb/tls/cert.pem /etc/foundationdb/tls/ca.pem

	# The key must match the certificate. They are separate secrets, so nothing else checks
	# they were rotated together -- and a mismatched pair fails at handshake time, on a peer,
	# as a connection error rather than as a configuration error. Compared here, where the
	# message can say what is actually wrong.
	cpub=$(openssl x509 -in /etc/foundationdb/tls/cert.pem -noout -pubkey 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')
	kpub=$(openssl pkey -in /etc/foundationdb/tls/key.pem -pubout 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')
	if [ -z "$cpub" ] || [ "$cpub" != "$kpub" ]; then
		echo "the TLS key does not match the certificate" >&2
		echo "  cert public key sha256 ${cpub:-unreadable}" >&2
		echo "  key  public key sha256 ${kpub:-unreadable}" >&2
		exit 1
	fi

	subject=$(openssl x509 -in /etc/foundationdb/tls/cert.pem -noout -subject 2>/dev/null | sed 's/^subject=//')
	notafter=$(openssl x509 -in /etc/foundationdb/tls/cert.pem -noout -enddate | sed 's/notAfter=//')
	VERIFY=${WEFT_FDB_TLS_VERIFY:?set WEFT_FDB_TLS_VERIFY when TLS material is given}
	log "TLS on: subject [$subject] expires $notafter"
	log "TLS verify_peers: $VERIFY"
	tls=1

	export FDB_TLS_CERTIFICATE_FILE=/etc/foundationdb/tls/cert.pem
	export FDB_TLS_KEY_FILE=/etc/foundationdb/tls/key.pem
	export FDB_TLS_CA_FILE=/etc/foundationdb/tls/ca.pem
	export FDB_TLS_VERIFY_PEERS="$VERIFY"
else
	log "TLS off: no FDB_TLS_CERT_B64. Every byte between these processes is in the clear."
fi
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
	if [ "$tls" = 1 ]; then
		echo "public_address = [$self]:\$ID:tls"
		echo "tls_certificate_file = /etc/foundationdb/tls/cert.pem"
		echo "tls_key_file = /etc/foundationdb/tls/key.pem"
		echo "tls_ca_file = /etc/foundationdb/tls/ca.pem"
		echo "tls_verify_peers = $VERIFY"
	else
		echo "public_address = [$self]:\$ID"
	fi
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
