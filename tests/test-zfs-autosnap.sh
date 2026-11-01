#!/usr/bin/env bash
# zfs-autosnap against a fake `zfs` that keeps its snapshots in a text file.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/snippets/storage-zfs-snapshots/files/opt/bin/zfs-autosnap"
work="$(mktemp -d)"
mkdir "$work/bin"

# Fake zfs: understands exactly the three calls zfs-autosnap makes.
# The state file lists snapshots in creation order, one per line. A dataset
# named in FAKE_ZFS_MISSING doesn't exist.
cat >"$work/bin/zfs" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_ZFS_STATE"
echo "$*" >>"$state.calls"
case "$1" in
snapshot)
	if [ "${3%@*}" = "${FAKE_ZFS_MISSING:-}" ]; then
		echo "cannot open '${3%@*}': dataset does not exist" >&2
		exit 1
	fi
	echo "$3" >>"$state" ;;
list) grep "^${!#}@" "$state" || true ;;
destroy)
	[ "$3" != "${FAKE_ZFS_DESTROY_FAILS:-}" ] || { echo "cannot destroy '$3'" >&2; exit 1; }
	grep -vxF "$3" "$state" >"$state.tmp" || true; mv "$state.tmp" "$state" ;;
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
		tank/quaipa@autosnap-hourly-20260101T0100Z \
		tank/quaipa@autosnap-hourly-20260101T0200Z \
		tank/quaipa@autosnap-hourly-20260101T0300Z \
		tank/quaipa@autosnap-hourly-20260101T0400Z \
		tank/other@autosnap-hourly-20260101T0100Z \
		>"$work/state"
	touch "$work/state.calls"
}

conf() { printf '%s\n' "$@" >"$work/conf"; }

run() {
	PATH="$work/bin:$PATH" FAKE_ZFS_STATE="$work/state" ZFS_AUTOSNAP_CONF="$work/conf" FAKE_ZFS_MISSING="${missing:-}" \
		FAKE_ZFS_DESTROY_FAILS="${destroy_fails:-}" \
		bash "$SCRIPT" "$@"
}

count() { grep -c "^${2:-tank/projects}@autosnap-$1-" "$work/state" || true; }

good_conf() {
	conf AUTOSNAP_DATASETS=tank/projects AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2
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

# --- several trees: each its own snapshot and pruning --------------------------
two_conf() {
	conf 'AUTOSNAP_DATASETS="tank/projects tank/quaipa"' AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2
}
seed; two_conf
check "two trees: hourly run succeeds" run hourly
check "two trees: projects snapshotted" grep -q '^snapshot -r tank/projects@autosnap-hourly-' "$work/state.calls"
check "two trees: quaipa snapshotted" grep -q '^snapshot -r tank/quaipa@autosnap-hourly-' "$work/state.calls"
check "two trees: projects pruned to 3" test "$(count hourly)" = 3
check "two trees: quaipa pruned to 3" test "$(count hourly tank/quaipa)" = 3
check "two trees: quaipa's two oldest destroyed" test -z "$(grep -E 'tank/quaipa@autosnap-hourly-20260101T0[12]00Z' "$work/state" || true)"
check "two trees: other dataset untouched" grep -qx 'tank/other@autosnap-hourly-20260101T0100Z' "$work/state"

# A missing tree fails the run, loudly, but doesn't stop the others.
seed; two_conf
rc=0; missing=tank/projects run hourly 2>"$work/err" || rc=$?
check "missing tree: run fails" test "$rc" = 1
check "missing tree: says which" grep -q "tank/projects" "$work/err"
check "missing tree: the other still snapshotted" grep -q '^snapshot -r tank/quaipa@autosnap-hourly-' "$work/state.calls"
check "missing tree: the other still pruned" test "$(count hourly tank/quaipa)" = 3
check "missing tree: nothing of it destroyed" test -z "$(grep '^destroy -r tank/projects@' "$work/state.calls" || true)"

# A destroy that fails fails the run, even when a later one succeeds.
seed; two_conf
rc=0; destroy_fails=tank/quaipa@autosnap-hourly-20260101T0100Z run hourly 2>"$work/err" || rc=$?
check "failed prune: run fails" test "$rc" = 1
check "failed prune: says which" grep -q "tank/quaipa" "$work/err"
check "failed prune: the other tree still pruned" test "$(count hourly)" = 3

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
conf AUTOSNAP_DATASETS=tank/projects AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2; bad "missing keep for class" weekly
conf AUTOSNAP_DATASETS=tank/projects AUTOSNAP_KEEP_HOURLY=0 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "keep 0" hourly
conf AUTOSNAP_DATASETS=tank/projects AUTOSNAP_KEEP_HOURLY=x AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "keep not a number" hourly
conf AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "missing dataset list" hourly
conf 'AUTOSNAP_DATASETS="tank/*"' AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "a glob, never expanded" hourly
conf AUTOSNAP_DATASETS= AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "empty dataset list" hourly
conf 'AUTOSNAP_DATASETS="tank/projects tank/q@aipa"' AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "one bad tree among good ones" hourly
conf AUTOSNAP_DATASET=tank/projects AUTOSNAP_KEEP_HOURLY=3 AUTOSNAP_KEEP_DAILY=2 AUTOSNAP_KEEP_WEEKLY=2; bad "the old single-tree name" hourly
rm -f "$work/conf"; bad "missing config file" hourly

finish
