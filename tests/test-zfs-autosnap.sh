#!/usr/bin/env bash
# zfs-autosnap against a fake `zfs` that keeps its snapshots in a text file.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/snippets/storage-zfs-snapshots/files/opt/bin/zfs-autosnap"
work="$(mktemp -d)"
mkdir "$work/bin"

# Fake zfs: understands exactly the three calls zfs-autosnap makes.
# The state file lists snapshots in creation order, one per line.
cat >"$work/bin/zfs" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_ZFS_STATE"
echo "$*" >>"$state.calls"
case "$1" in
snapshot) echo "$3" >>"$state" ;;
list) grep "^${!#}@" "$state" || true ;;
destroy) grep -vxF "$3" "$state" >"$state.tmp" || true; mv "$state.tmp" "$state" ;;
*) echo "fake zfs: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/zfs"

seed() {
	rm -f "$work/state" "$work/state.calls"
	printf '%s\n' \
		tank/projects@before-upgrade \
		tank/projects@autosnap-daily-20260101T0000Z \
		tank/projects@autosnap-hourly-20260101T0100Z \
		tank/projects@autosnap-hourly-20260101T0200Z \
		tank/projects@autosnap-hourly-20260101T0300Z \
		tank/other@autosnap-hourly-20260101T0100Z \
		>"$work/state"
	touch "$work/state.calls"
}

conf() { printf '%s\n' "$@" >"$work/conf"; }

run() {
	PATH="$work/bin:$PATH" FAKE_ZFS_STATE="$work/state" ZFS_AUTOSNAP_CONF="$work/conf" \
		bash "$SCRIPT" "$@"
}

count() { grep -c "^tank/projects@autosnap-$1-" "$work/state" || true; }

good_conf() {
	conf AUTOSNAP_DATASET=tank/projects AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2
}

# --- snapshot + prune -----------------------------------------------------------
seed; good_conf
check "hourly run succeeds" run hourly
check "snapshot taken recursively" grep -q '^snapshot -r tank/projects@autosnap-hourly-' "$work/state.calls"
check "hourly pruned to 3" test "$(count hourly)" = 3
check "oldest hourly destroyed" test -z "$(grep -x 'tank/projects@autosnap-hourly-20260101T0100Z' "$work/state" || true)"
check "prune destroys recursively" grep -qx 'destroy -r tank/projects@autosnap-hourly-20260101T0100Z' "$work/state.calls"
check "manual snapshot untouched" grep -qx 'tank/projects@before-upgrade' "$work/state"
check "daily untouched by hourly run" test "$(count daily)" = 1
check "other dataset untouched" grep -qx 'tank/other@autosnap-hourly-20260101T0100Z' "$work/state"

seed; good_conf
check "daily below its limit prunes nothing" run daily
check "daily now 2" test "$(count daily)" = 2
check "no destroy when under limit" test -z "$(grep '^destroy' "$work/state.calls" || true)"

# --- fail closed: no zfs call at all on bad input ---------------------------
bad() { # bad <description> <args...> - must exit 2 and never call zfs
	seed
	local rc=0
	run "${@:2}" 2>/dev/null || rc=$?
	check "$1: exit 2" test "$rc" = 2
	check "$1: no zfs call" test ! -s "$work/state.calls"
}

good_conf; bad "unknown class" monthly
good_conf; bad "no class" 
conf AUTOSNAP_DATASET=tank/projects AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2; bad "missing keep for class" weekly
conf AUTOSNAP_DATASET=tank/projects AUTOSNAP_KEEP_HOURLY=0 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "keep 0" hourly
conf AUTOSNAP_DATASET=tank/projects AUTOSNAP_KEEP_HOURLY=x AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "keep not a number" hourly
conf AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "missing dataset" hourly
conf 'AUTOSNAP_DATASET="tank/p rojects"' AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "dataset with space" hourly
rm -f "$work/conf"; bad "missing config file" hourly

finish
