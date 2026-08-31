#!/bin/sh
# Assert the backup is fresh, from the one place that already holds the
# credentials: the cluster machine. CI has no production access and the spend
# keeper's authority should not grow a monitoring pattern, so the check runs
# beside the agents and publishes a health file that Fly's machine check
# reads. A failing check is visible in `fly status`; nothing new gets a
# secret.
#
# The signal is the backup layer's own metadata: `status json` reports
# last_restorable_seconds_behind, which advances only after the agents have
# durably written to the blob container, and running_backup, without which a
# small lag is a stopped backup coasting on its last snapshot. Listing the
# bucket directly was the first design and is the more physical measurement,
# but curl 7.88's SigV4 signs query strings unsorted and unencoded, so any
# prefix with a slash or a continuation token comes back 403
# SignatureDoesNotMatch -- a probe that cannot paginate cannot find the
# newest object.
#
#   backup-fresh.sh            loop forever, refresh /run/backup-fresh/health
#   backup-fresh.sh --self-test
set -eu

MAX_BEHIND=${WEFT_BACKUP_MAX_BEHIND:-3600}
CHECK_EVERY=${WEFT_BACKUP_CHECK_EVERY:-300}
HEALTH_DIR=/run/backup-fresh
VERIFY="Check.Valid=1,S.CN>=fdb-,S.CN<=.chibifire.com"

# verdict <running true|false> <seconds_behind>: fresh only when a backup is
# running AND its restorable point is close. Either signal missing is stale;
# an unreadable status must never read as fresh.
verdict() {
	[ "$1" = "true" ] || { echo stale; return; }
	behind=${2%%.*}
	case "$behind" in *[!0-9]*|"") echo stale; return;; esac
	if [ "$behind" -le "$MAX_BEHIND" ]; then echo fresh; else echo stale; fi
}

self_test() {
	# Both directions, or the loop is not armed: a planted defect the check
	# cannot flag is a check that certifies the defect.
	[ "$(verdict true 12.5)" = fresh ] || { echo "FAIL control: fresh read as stale" >&2; return 1; }
	[ "$(verdict true $((MAX_BEHIND + 100)))" = stale ] || { echo "FAIL control: planted lag read as fresh" >&2; return 1; }
	[ "$(verdict false 12.5)" = stale ] || { echo "FAIL control: stopped backup read as fresh" >&2; return 1; }
	[ "$(verdict true garbage)" = stale ] || { echo "FAIL control: unreadable lag read as fresh" >&2; return 1; }
	echo "ok   4 of 4 controls fired"
}

if [ "${1:-}" = "--self-test" ]; then
	self_test
	exit $?
fi

self_test || exit 1
mkdir -p "$HEALTH_DIR"

while :; do
	json=$(timeout 30 fdbcli \
		--tls_certificate_file /etc/foundationdb/tls/cert.pem \
		--tls_key_file /etc/foundationdb/tls/key.pem \
		--tls_ca_file /etc/foundationdb/tls/ca.pem \
		--tls_verify_peers "$VERIFY" \
		--exec "status json" 2>/dev/null || true)
	running=$(printf '%s' "$json" | grep -oE '"running_backup"[^,}]*' | grep -oE 'true|false' | head -1)
	behind=$(printf '%s' "$json" | grep -oE '"last_restorable_seconds_behind"[^,}]*' | grep -oE '[0-9.]+' | head -1)
	if [ "$(verdict "${running:-false}" "${behind:-x}")" = fresh ]; then
		echo ok > "$HEALTH_DIR/health"
	else
		rm -f "$HEALTH_DIR/health"
		echo "[backup-fresh] BACKUP STALE: running=${running:-unreadable} seconds_behind=${behind:-unreadable} max=${MAX_BEHIND}" >&2
	fi
	sleep "$CHECK_EVERY"
done
