#!/usr/bin/env bash
# restic-backup against fake `zfs`, `restic` and `curl` that log their calls.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/snippets/storage-restic-backup/files/opt/bin/restic-backup"
URL="https://ping.example/secret-check-uuid"
PASSWORD="secret-restic-password"
work="$(mktemp -d)"
mkdir "$work/bin"

# Fake zfs: understands exactly the three calls restic-backup makes. Each
# project is $work/z/<name>/created and $work/z/<name>/snaps, the latter as
# "<snapshot name> <creation>" lines, oldest first. Its mountpoint is $work/mnt/<name>.
cat >"$work/bin/zfs" <<'EOF'
#!/usr/bin/env bash
echo "zfs $*" >>"$FAKE_CALLS"
ds="${!#}"
name="${ds##*/}"
case "$*" in
"list -H -o name,mountpoint -d 1 "*)
	[ -z "${FAKE_ROOT_MISSING:-}" ] || { echo "cannot open '$ds': dataset does not exist" >&2; exit 1; }
	printf '%s\t%s\n' "$ds" "/$ds"
	for p in "$FAKE_Z"/*; do
		[ -d "$p" ] || continue
		printf '%s\t%s\n' "$ds/${p##*/}" "$FAKE_MNT/${p##*/}"
	done ;;
"list -Hp -t snapshot -o name,creation -s creation -d 1 "*)
	while read -r snap created; do printf '%s@%s\t%s\n' "$ds" "$snap" "$created"; done <"$FAKE_Z/$name/snaps" ;;
"list -Hp -o creation "*) cat "$FAKE_Z/$name/created" ;;
*) echo "fake zfs: unexpected call: $*" >&2; exit 1 ;;
esac
EOF

# Fake restic: logs its arguments and where it ran. FAKE_RESTIC_FAIL is a regex
# on that log line: a match fails the call.
cat >"$work/bin/restic" <<'EOF'
#!/usr/bin/env bash
line="restic $* @$PWD"
echo "$line" >>"$FAKE_CALLS"
if [ -n "${FAKE_RESTIC_FAIL:-}" ] && [[ "$line" =~ $FAKE_RESTIC_FAIL ]]; then
	echo "fake restic: failed" >&2
	exit 1
fi
EOF

cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_CALLS"
exit "${FAKE_CURL_RC:-0}"
EOF
chmod +x "$work/bin/"*

now="$(date +%s)"
hours_ago() { echo $((now - $1 * 3600)); }

# project <name> <age of its newest daily in hours> - with older and other snapshots around it
project() {
	mkdir -p "$work/z/$1"
	hours_ago 2000 >"$work/z/$1/created"
	{
		echo "autosnap-daily-old $(hours_ago 100)"
		echo "manual-after $(hours_ago 90)"
		echo "autosnap-daily-newest $(hours_ago "$2")"
		echo "autosnap-hourly-later $(hours_ago 0)"
		echo "pre-upgrade $(hours_ago 0)"
	} >"$work/z/$1/snaps"
	mkdir -p "$work/mnt/$1/.zfs/snapshot/autosnap-daily-newest"
}

reset() {
	find "$work" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -r {} +
	mkdir "$work/z" "$work/mnt"
	touch "$work/calls"
}

good_conf() {
	printf '%s\n' BACKUP_ROOT=tank/projects BACKUP_KEEP_DAILY=7 BACKUP_KEEP_WEEKLY=4 BACKUP_KEEP_MONTHLY=6 BACKUP_MAX_AGE_HOURS=48 >"$work/conf"
}

# run - sets rc, keeps all output in $work/out. Secrets go in the environment,
# as systemd does it. Empty repository or url leave those out.
run() {
	rc=0
	env PATH="$work/bin:$PATH" FAKE_CALLS="$work/calls" FAKE_Z="$work/z" FAKE_MNT="$work/mnt" \
		RESTIC_BACKUP_CONF="$work/conf" \
		RESTIC_REPOSITORY="${repository-swift:c:/}" RESTIC_PASSWORD="${password-$PASSWORD}" HEALTHCHECK_URL="${url-$URL}" \
		bash "$SCRIPT" >>"$work/out" 2>&1 || rc=$?
	touch "$work/out"
	if grep -qF -e "$URL" -e "$PASSWORD" "$work/out"; then
		leaked=1
	fi
}

called() { grep -qF -- "$1" "$work/calls"; }
not_called() { ! called "$1"; }
pinged() { grep -q '^curl ' "$work/calls"; }
not_pinged() { ! pinged; }
in_log() { grep -qF -- "$1" "$work/out"; }

leaked=0
BACKUP="restic backup --tag hello --group-by tags . @$work/mnt/hello/.zfs/snapshot/autosnap-daily-newest"
MOSER="restic backup --tag moser --group-by tags . @$work/mnt/moser/.zfs/snapshot/autosnap-daily-newest"
FORGET="restic forget --group-by tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune"
CHECK="restic check"
PING="curl -fsS -m 10 --retry 3 $URL"

# --- two projects, all good ---------------------------------------------------
reset; good_conf; project hello 3; project moser 3; run
check "two projects: exit 0" test "$rc" = 0
check "two projects: hello from its newest daily" called "$BACKUP"
check "two projects: moser from its newest daily" called "$MOSER"
check "two projects: no hourly or manual snapshot read" not_called "autosnap-hourly"
check "two projects: the root itself isn't backed up" not_called "--tag projects"

order="$(grep -nE '^(restic (backup|forget|check)|curl)' "$work/calls" | sed -E 's/^[0-9]+:(restic [a-z]+|curl).*/\1/' | tr '\n' ',')"
check "order: backups, forget, check, one ping" test "$order" = "restic backup,restic backup,restic forget,restic check,curl,"
check "order: exact forget" called "$FORGET"
check "order: exact ping" called "$PING"
check "order: stale locks cleared first" test "$(sed -n 's/^\(restic [a-z]*\).*/\1/p' "$work/calls" | head -n1)" = "restic unlock"

# --- failures withhold the ping -----------------------------------------------
reset; good_conf; project hello 3; project moser 3; FAKE_RESTIC_FAIL='^restic backup.*--tag hello' run
check "one backup fails: exit 1" test "$rc" = 1
check "one backup fails: the other still runs" called "$MOSER"
check "one backup fails: forget still runs" called "$FORGET"
check "one backup fails: check still runs" called "$CHECK"
check "one backup fails: no ping" not_pinged
check "one backup fails: says which" in_log "hello"

reset; good_conf; project hello 3; FAKE_RESTIC_FAIL='^restic forget' run
check "forget fails: exit 1" test "$rc" = 1
check "forget fails: no ping" not_pinged

reset; good_conf; project hello 3; FAKE_RESTIC_FAIL='^restic check' run
check "check fails: exit 1" test "$rc" = 1
check "check fails: no ping" not_pinged

reset; good_conf; project hello 3; FAKE_RESTIC_FAIL='^restic unlock' run
check "unlock fails: exit 1" test "$rc" = 1
check "unlock fails: no ping" not_pinged

# --- snapshots too old, or missing --------------------------------------------
reset; good_conf; project hello 49; project moser 3; run
check "stale daily: exit 1" test "$rc" = 1
check "stale daily: not backed up" not_called "--tag hello"
check "stale daily: the other still runs" called "$MOSER"
check "stale daily: no ping" not_pinged
check "stale daily: says which" in_log "hello"
check "stale daily: says how old" in_log "49"

reset; good_conf; project hello 3; project moser 3; hours_ago 2 >"$work/z/moser/created"; : >"$work/z/moser/snaps"; run
check "new project, no daily: exit 0" test "$rc" = 0
check "new project, no daily: skipped" not_called "--tag moser"
check "new project, no daily: says so" in_log "moser"
check "new project, no daily: others run" called "$BACKUP"
check "new project, no daily: still pings" pinged

reset; good_conf; project hello 3; project moser 3; : >"$work/z/moser/snaps"; run
check "old project, no daily: exit 1" test "$rc" = 1
check "old project, no daily: says which" in_log "moser"
check "old project, no daily: others run" called "$BACKUP"
check "old project, no daily: no ping" not_pinged

reset; good_conf; project hello 3; rm -rf "$work/mnt/hello"; run
check "snapshot not readable: exit 1" test "$rc" = 1
check "snapshot not readable: no ping" not_pinged

# --- nothing to back up must never look like success ---------------------------
reset; good_conf; run
check "no children: exit 1" test "$rc" = 1
check "no children: no restic call" not_called "restic"
check "no children: no ping" not_pinged

reset; good_conf; project hello 3; FAKE_ROOT_MISSING=1 run
check "root missing: exit 1" test "$rc" = 1
check "root missing: no restic call" not_called "restic"
check "root missing: no ping" not_pinged

# --- the reason comes last, where the log's tail shows it ------------------------
last_line() { tail -n 1 "$work/out"; }
reset; good_conf; project hello 49; project moser 3; run
check "failures named last: stale" test "$(last_line)" = "restic-backup: failed: hello"
reset; good_conf; project hello 3; project moser 3; FAKE_RESTIC_FAIL='^restic (backup.*--tag (hello|moser)|forget|check|unlock)' run
check "failures named last: all of them" test "$(last_line)" = "restic-backup: failed: unlock hello moser prune check"

# --- all skipped: nothing was backed up, so that can't look like success --------
reset; good_conf; project moser 3; hours_ago 2 >"$work/z/moser/created"; : >"$work/z/moser/snaps"; run
check "all skipped: exit 1" test "$rc" = 1
check "all skipped: no ping" not_pinged
check "all skipped: says so" test "$(last_line)" = "restic-backup: failed: nothing backed up"

# --- a failed ping doesn't fail the backup --------------------------------------
reset; good_conf; project hello 3; FAKE_CURL_RC=7 run
check "ping fails: exit 0" test "$rc" = 0
check "ping fails: logged" in_log "ping failed"

# --- fail closed: nothing called on bad input ----------------------------------
bad() { # bad <description> - after the caller set up conf and env: exit 2, no call at all
	check "$1: exit 2" test "$rc" = 2
	check "$1: no call" test ! -s "$work/calls"
}
reset; good_conf; project hello 3; repository='' run; bad "no repository"
reset; good_conf; project hello 3; password='' run; bad "no password"
reset; good_conf; project hello 3; url='' run; bad "no url"
reset; good_conf; project hello 3; sed -i 's/KEEP_DAILY=7/KEEP_DAILY=x/' "$work/conf"; run; bad "bad keep daily"
reset; good_conf; project hello 3; sed -i '/KEEP_MONTHLY/d' "$work/conf"; run; bad "missing keep monthly"
reset; good_conf; project hello 3; sed -i 's/MAX_AGE_HOURS=48/MAX_AGE_HOURS=0/' "$work/conf"; run; bad "bad max age"
reset; good_conf; project hello 3; sed -i 's|BACKUP_ROOT=.*|BACKUP_ROOT="tank; rm"|' "$work/conf"; run; bad "bad root"
reset; project hello 3; rm -f "$work/conf"; run; bad "no config file"

# --- secrets --------------------------------------------------------------------
check "no case printed the url or the password" test "$leaked" = 0

rm -rf "$work"
finish
