#!/bin/sh
# Assert the backup in the bucket is fresh, from the one place that already
# holds the credentials: the cluster machine. CI has no production access and
# the spend keeper's authority should not grow a monitoring pattern, so the
# check runs beside the agents and publishes a health file that Fly's machine
# check reads. A failing check is visible in `fly status`; nothing new gets a
# secret.
#
# The physical quantity is the age of the newest object under data/ in the
# bucket -- what a restore would actually find -- not fdbbackup's opinion of
# itself. Listing goes through the same loopback hop the agents use, so this
# also fails when the hop does.
#
#   backup-fresh.sh            loop forever, refresh /run/backup-fresh/health
#   backup-fresh.sh --self-test
set -eu

: "${AWS_ACCESS_KEY_ID:?}"
: "${AWS_SECRET_ACCESS_KEY:?}"
: "${BUCKET_NAME:?}"
blob_host=$(printf '%s' "${AWS_ENDPOINT_URL_S3:?}" | sed -e 's|^https\?://||' -e 's|/.*$||')

# Snapshot cadence bounds how old the newest *snapshot* may be, but mutation
# logs land continuously, so a healthy backup writes far more often than the
# interval. The default gives the agents an hour of quiet before this calls
# them stale; WEFT_BACKUP_MAX_AGE overrides it.
MAX_AGE=${WEFT_BACKUP_MAX_AGE:-3600}
CHECK_EVERY=${WEFT_BACKUP_CHECK_EVERY:-300}
HEALTH_DIR=/run/backup-fresh

newest_epoch() {
	# Paginate the full data/ prefix and keep the maximum LastModified. An
	# unreadable listing returns nothing, and the caller treats nothing as
	# stale: a check that cannot see the bucket must not report fresh.
	token=""
	max=0
	while :; do
		url="http://${blob_host}:8443/${BUCKET_NAME}?list-type=2&prefix=data/&max-keys=1000${token}"
		page=$(curl -sf --max-time 30 "$url" \
			--user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
			--aws-sigv4 "aws:amz:auto:s3") || return 1
		for ts in $(printf '%s' "$page" | grep -oE '<LastModified>[^<]+' | cut -d'>' -f2); do
			e=$(date -d "$ts" +%s 2>/dev/null) || continue
			[ "$e" -gt "$max" ] && max=$e
		done
		next=$(printf '%s' "$page" | grep -oE '<NextContinuationToken>[^<]+' | cut -d'>' -f2 || true)
		[ -n "$next" ] || break
		token="&continuation-token=$(printf '%s' "$next" | sed 's|=|%3D|g;s|+|%2B|g;s|/|%2F|g')"
	done
	[ "$max" -gt 0 ] || return 1
	echo "$max"
}

verdict() {
	# fresh|stale from a newest-object epoch, against now.
	age=$(( $(date +%s) - $1 ))
	if [ "$age" -le "$MAX_AGE" ]; then echo fresh; else echo stale; fi
}

self_test() {
	# Both directions, or the loop is not armed: a planted stale timestamp the
	# check cannot flag is a check that certifies the defect.
	old=$(( $(date +%s) - MAX_AGE - 100 ))
	new=$(( $(date +%s) - 1 ))
	[ "$(verdict "$old")" = stale ] || { echo "FAIL control: planted stale read as fresh" >&2; return 1; }
	[ "$(verdict "$new")" = fresh ] || { echo "FAIL control: fresh read as stale" >&2; return 1; }
	echo "ok   2 of 2 controls fired"
}

if [ "${1:-}" = "--self-test" ]; then
	self_test
	exit $?
fi

self_test || exit 1
mkdir -p "$HEALTH_DIR"

while :; do
	if epoch=$(newest_epoch) && [ "$(verdict "$epoch")" = fresh ]; then
		echo ok > "$HEALTH_DIR/health"
	else
		rm -f "$HEALTH_DIR/health"
		echo "[backup-fresh] BACKUP STALE: newest data/ object older than ${MAX_AGE}s (or bucket unreadable)" >&2
	fi
	sleep "$CHECK_EVERY"
done
