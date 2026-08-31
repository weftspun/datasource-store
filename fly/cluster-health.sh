#!/bin/sh
# Gate the deploy roll on the cluster healing, the way the Kubernetes FDB
# operator does: Fly advances a rolling deploy only when every machine check
# passes, so this check failing after a restart holds the roll until
# re-replication has finished. Without it, the next machine can restart while
# a shard's only healthy replica is still catching up, and with double
# redundancy those ranges stall until a machine returns.
#
# Two signals from `status json`, both required: the data state names itself
# healthy, and the cluster can lose a zone without losing data. During
# healing the second reads 0 -- the exact window the roll must wait out.
#
#   cluster-health.sh            loop forever, refresh /run/backup-fresh/cluster
#   cluster-health.sh --self-test
set -eu

CHECK_EVERY=${WEFT_CLUSTER_CHECK_EVERY:-30}
HEALTH_DIR=/run/backup-fresh
VERIFY="Check.Valid=1,S.CN>=fdb-,S.CN<=.chibifire.com"

# verdict <data_healthy yes|no> <zone_failures_tolerated>: an unreadable
# status must never read as healthy.
verdict() {
	[ "$1" = "yes" ] || { echo unhealthy; return; }
	case "$2" in *[!0-9]*|"") echo unhealthy; return;; esac
	if [ "$2" -ge 1 ]; then echo healthy; else echo unhealthy; fi
}

self_test() {
	[ "$(verdict yes 1)" = healthy ] || { echo "FAIL control: healthy read as unhealthy" >&2; return 1; }
	[ "$(verdict no 1)" = unhealthy ] || { echo "FAIL control: planted unhealthy data state read as healthy" >&2; return 1; }
	[ "$(verdict yes 0)" = unhealthy ] || { echo "FAIL control: zero fault tolerance read as healthy" >&2; return 1; }
	[ "$(verdict yes garbage)" = unhealthy ] || { echo "FAIL control: unreadable tolerance read as healthy" >&2; return 1; }
	echo "ok   4 of 4 controls fired"
}

if [ "${1:-}" = "--self-test" ]; then
	self_test
	exit $?
fi

self_test || exit 1
mkdir -p "$HEALTH_DIR"

tls_args=""
if [ -f /etc/foundationdb/tls/cert.pem ]; then
	tls_args="--tls_certificate_file /etc/foundationdb/tls/cert.pem \
		--tls_key_file /etc/foundationdb/tls/key.pem \
		--tls_ca_file /etc/foundationdb/tls/ca.pem \
		--tls_verify_peers $VERIFY"
fi

while :; do
	# shellcheck disable=SC2086
	json=$(timeout 25 fdbcli $tls_args --exec "status json" 2>/dev/null || true)
	healthy=no
	printf '%s' "$json" | grep -qE '"name" : "healthy' && healthy=yes
	zones=$(printf '%s' "$json" \
		| grep -oE '"max_zone_failures_without_losing_data"[^,}]*' \
		| grep -oE '[0-9]+' | head -1)
	if [ "$(verdict "$healthy" "${zones:-x}")" = healthy ]; then
		echo ok > "$HEALTH_DIR/cluster"
	else
		rm -f "$HEALTH_DIR/cluster"
		echo "[cluster-health] UNHEALTHY: data_healthy=$healthy zone_tolerance=${zones:-unreadable}" >&2
	fi
	sleep "$CHECK_EVERY"
done
