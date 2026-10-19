#!/usr/bin/env bash
# k3s-swap against stub systemctl, systemd-sysext, curl, zfs, findmnt,
# mountpoint, pgrep and k3s, in a fake root (K3S_SWAP_ROOT).
# shellcheck disable=SC2016 # stub bodies are literal shell
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$REPO_ROOT/snippets/app-k3s-server/files/opt/bin/k3s-swap"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
root="$work/root"
calls="$work/calls"

# One stub per command; each logs "<name> <args>" to the call log. The
# bodies are literal shell for the stub, hence single quotes (SC2016).
stub() { # stub <name> <body>
	printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_CALLS"\n%s\n' "$1" "$2" >"$work/bin/$1"
	chmod +x "$work/bin/$1"
}
stub systemctl 'if [ "$1" = is-active ]; then exit "${FAKE_ACTIVE:-3}"; fi; exit 0'
stub systemd-sysext 'exit "${FAKE_REFRESH_RC:-0}"'
stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then printf %s "$FAKE_RAW" >"$2"; fi; shift; done'
stub zfs 'if [ "$1" = list ]; then exit "${FAKE_SNAP_RC:-0}"; fi; exit 0'
stub findmnt 'echo tank/system/containerd'
stub mountpoint 'exit "${FAKE_MOUNTED:-0}"'
stub pgrep 'exit "${FAKE_SHIMS:-1}"'
stub k3s 'case "$*" in *kubeletVersion*) echo "$FAKE_KUBELET" ;; esac; exit 0'
stub update_engine_client 'echo "${FAKE_UE_STATUS:-CURRENT_OP=UPDATE_STATUS_IDLE}"'
# cp works for real unless FAKE_CP_FAIL is set (a full disk mid-copy).
stub cp "[ -z \"\${FAKE_CP_FAIL:-}\" ] || exit 1; exec $(command -v cp) \"\$@\""

FAKE_RAW="new k3s sysext"
SHA="$(printf %s "$FAKE_RAW" | sha256sum | cut -d' ' -f1)"
EXT="$root/opt/extensions/k3s"
LINK="$root/etc/extensions/k3s.raw"
STATE="$root/var/lib/rancher/k3s-swap"
DB="$root/var/lib/rancher/k3s/server/db/state.db"

seed() {
	rm -rf "$root" && : >"$calls"
	mkdir -p "$EXT" "$root/etc/extensions" "$(dirname "$DB")" "$root/var/lib/rancher/k3s/agent/containerd"
	echo old >"$EXT/k3s-v1.36.4+k3s1-x86-64.raw"
	ln -s /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw "$LINK"
	echo "datastore before" >"$DB"
}

# run <args...> - sets rc, out
run() {
	rc=0
	out="$(PATH="$work/bin:$PATH" FAKE_CALLS="$calls" K3S_SWAP_ROOT="$root" \
		FAKE_RAW="$FAKE_RAW" FAKE_KUBELET="${FAKE_KUBELET:-}" \
		K3S_SWAP_TIMEOUT="${K3S_SWAP_TIMEOUT:-5}" bash "$SCRIPT" "$@" 2>&1)" || rc=$?
}

# acting <name> - succeed if the call log has a state-changing call of <name>
acting() { grep -qE "^$1( |$)" "$calls"; }
no_action() { ! acting systemctl && ! acting zfs && ! acting curl && ! acting systemd-sysext; }
# in_order <line...> - the lines appear in the call log in this order
in_order() {
	local want
	for want in "$@"; do
		grep -qxF -- "$want" "$calls" || return 1
	done
	[ "$(grep -xF "${@/#/-e}" "$calls" | tr '\n' '|')" = "$(printf '%s|' "$@")" ]
}

# --- status -------------------------------------------------------------------
seed; run status
check "status succeeds" test "$rc" = 0
check "status: current version" contains "$out" "current: v1.36.4+k3s1"
check "status: no swap" contains "$out" "swap: none"

# --- to: next minor -----------------------------------------------------------
seed; FAKE_KUBELET=v1.37.1+k3s1 run to v1.37.1+k3s1 "$SHA"
check "minor swap succeeds" test "$rc" = 0
check "new sysext in place" test "$(cat "$EXT/k3s-v1.37.1+k3s1-x86-64.raw" 2>/dev/null)" = "$FAKE_RAW"
check "symlink points to the new sysext" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.37.1+k3s1-x86-64.raw
check "old sysext kept for rollback" test -f "$EXT/k3s-v1.36.4+k3s1-x86-64.raw"
check "state: from" test "$(cat "$STATE/from" 2>/dev/null)" = v1.36.4+k3s1
check "state: to" test "$(cat "$STATE/to" 2>/dev/null)" = v1.37.1+k3s1
check "state: datastore copied" test "$(cat "$STATE/server/db/state.db" 2>/dev/null)" = "datastore before"
check "downloads from the Flatcar extensions server" grep -qxF \
	"curl -fsSL --retry 3 -o $EXT/k3s-v1.37.1+k3s1-x86-64.raw.partial https://extensions.flatcar.org/extensions/k3s-v1.37.1+k3s1-x86-64.raw" "$calls"
check "stop, snapshot, refresh, start, in order" in_order \
	"systemctl stop k3s" \
	"zfs snapshot tank/system/containerd@k3s-swap-pre" \
	"systemd-sysext refresh" \
	"systemctl start k3s"
check "prints old -> new" contains "$out" "k3s: v1.36.4+k3s1 -> v1.37.1+k3s1"
run status
check "status: swap recorded" contains "$out" "swap: v1.36.4+k3s1 -> v1.37.1+k3s1"

# --- to: patch ----------------------------------------------------------------
seed; FAKE_KUBELET=v1.36.5+k3s1 run to v1.36.5+k3s1 "$SHA"
check "patch swap succeeds" test "$rc" = 0
seed; FAKE_KUBELET=v1.36.4+k3s2 run to v1.36.4+k3s2 "$SHA"
check "k3s revision swap succeeds" test "$rc" = 0

# --- refusals: exit 2, nothing changed ------------------------------------------
refused() { # refused <description> <args...>
	seed
	run "${@:2}"
	check "$1: exit 2" test "$rc" = 2
	check "$1: no action" no_action
}
refused "no args"
refused "unknown subcommand" upgrade v1.37.1+k3s1 "$SHA"
refused "to without sha" to v1.37.1+k3s1
refused "version without v" to 1.37.1+k3s1 "$SHA"
refused "version with junk" to "v1.37.1+k3s1;rm" "$SHA"
refused "sha too short" to v1.37.1+k3s1 "${SHA:1}"
refused "sha uppercase" to v1.37.1+k3s1 "$(tr a-f A-F <<<"$SHA")"
refused "same version" to v1.36.4+k3s1 "$SHA"
refused "older patch" to v1.36.3+k3s1 "$SHA"
refused "older k3s revision" to v1.36.4+k3s0 "$SHA"
refused "older minor" to v1.35.9+k3s1 "$SHA"
refused "skipped minor" to v1.38.0+k3s1 "$SHA"

seed; FAKE_MOUNTED=1 run to v1.37.1+k3s1 "$SHA"
check "containerd dataset not mounted: exit 2" test "$rc" = 2
check "containerd dataset not mounted: no action" no_action

seed; mkdir -p "$STATE"; echo v1.35.0+k3s1 >"$STATE/from"
run to v1.37.1+k3s1 "$SHA"
check "earlier swap not cleaned: exit 2" test "$rc" = 2
check "earlier swap not cleaned: no action" no_action
check "earlier swap not cleaned: backup untouched" test "$(cat "$STATE/from")" = v1.35.0+k3s1

# --- failures: exit 1 ------------------------------------------------------------
seed; run to v1.37.1+k3s1 "$(printf %s other | sha256sum | cut -d' ' -f1)"
check "hash mismatch: exit 1" test "$rc" = 1
check "hash mismatch: nothing left behind" test -z "$(find "$EXT" -name 'k3s-v1.37.1*')"
check "hash mismatch: k3s never stopped" test -z "$(grep -x 'systemctl stop k3s' "$calls" || true)"
check "hash mismatch: symlink unchanged" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw

seed; FAKE_REFRESH_RC=1 FAKE_KUBELET=v1.37.1+k3s1 run to v1.37.1+k3s1 "$SHA"
check "refresh fails: exit 1" test "$rc" = 1
check "refresh fails: from recorded" test "$(cat "$STATE/from" 2>/dev/null)" = v1.36.4+k3s1
check "refresh fails: datastore copied" test -f "$STATE/server/db/state.db"
check "refresh fails: no to" test ! -e "$STATE/to"
check "refresh fails: names rollback" contains "$out" "k3s-swap rollback"

seed; FAKE_KUBELET=v1.36.4+k3s1 K3S_SWAP_TIMEOUT=0 run to v1.37.1+k3s1 "$SHA"
check "node keeps old version: exit 1" test "$rc" = 1
check "node keeps old version: names rollback" contains "$out" "k3s-swap rollback"
check "node keeps old version: no to" test ! -e "$STATE/to"

# --- rollback ---------------------------------------------------------------------
swapped() { # a completed swap v1.36.4 -> v1.37.1, call log cleared
	seed
	FAKE_KUBELET=v1.37.1+k3s1 run to v1.37.1+k3s1 "$SHA"
	echo "datastore after" >"$DB"
	: >"$calls"
}

seed; run rollback
check "rollback without a swap: exit 2" test "$rc" = 2
check "rollback without a swap: no action" no_action

swapped; run rollback
check "rollback succeeds" test "$rc" = 0
check "rollback masks k3s" grep -qx 'systemctl mask k3s' "$calls"
check "rollback marks pending" test -e "$STATE/rollback-pending"
check "rollback touches no dataset before the reboot" test -z "$(grep '^zfs' "$calls" || true)"
check "rollback says to reboot" contains "$out" "k3s-swap rollback-finish"
run status
check "status: rollback pending" contains "$out" "rollback pending"
run rollback
check "rollback twice: exit 2" test "$rc" = 2
FAKE_KUBELET=v1.37.1+k3s1 run to v1.37.1+k3s1 "$SHA"
check "to while rollback pending: exit 2" test "$rc" = 2

swapped; run rollback-finish
check "finish without rollback: exit 2" test "$rc" = 2
check "finish without rollback: no action" no_action

swapped; run rollback; : >"$calls"
FAKE_ACTIVE=0 run rollback-finish
check "finish while k3s runs: exit 2" test "$rc" = 2
check "finish while k3s runs: no zfs call" test -z "$(grep '^zfs' "$calls" || true)"
FAKE_SHIMS=0 run rollback-finish
check "finish while a shim runs: exit 2" test "$rc" = 2
check "finish while a shim runs: no zfs call" test -z "$(grep '^zfs' "$calls" || true)"

FAKE_KUBELET=v1.36.4+k3s1 run rollback-finish
check "finish succeeds" test "$rc" = 0
check "finish: datastore restored" test "$(cat "$DB" 2>/dev/null)" = "datastore before"
check "finish: containerd rolled back, then the snapshot dropped" in_order \
	"zfs rollback -r tank/system/containerd@k3s-swap-pre" \
	"zfs destroy tank/system/containerd@k3s-swap-pre"
check "finish: symlink back to the old sysext" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw
check "finish: new sysext removed" test ! -e "$EXT/k3s-v1.37.1+k3s1-x86-64.raw"
check "finish: refresh, unmask, start, in order" in_order \
	"systemd-sysext refresh" "systemctl unmask k3s" "systemctl start k3s"
check "finish: swap state gone" test ! -e "$STATE"
run status
check "status after rollback: none" contains "$out" "swap: none"
check "status after rollback: old version" contains "$out" "current: v1.36.4+k3s1"

seed; FAKE_REFRESH_RC=1 run to v1.37.1+k3s1 "$SHA"
run rollback
FAKE_KUBELET=v1.36.4+k3s1 run rollback-finish
check "rollback after a failed swap succeeds" test "$rc" = 0
check "rollback after a failed swap: back on the old sysext" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw

# --- clean ------------------------------------------------------------------------
swapped; run clean
check "clean succeeds" test "$rc" = 0
check "clean: swap state gone" test ! -e "$STATE"
check "clean: snapshot dropped" grep -qx 'zfs destroy tank/system/containerd@k3s-swap-pre' "$calls"
check "clean: only the current sysext left" test "$(ls "$EXT")" = k3s-v1.37.1+k3s1-x86-64.raw
check "clean: symlink unchanged" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.37.1+k3s1-x86-64.raw
check "clean: k3s untouched" test -z "$(grep '^systemctl' "$calls" | grep -v '^systemctl is-active' || true)"
check "clean: warns when k3s isn't running" contains "$out" "k3s is not running"

seed; echo stray >"$EXT/k3s-v1.35.0+k3s1-x86-64.raw"
FAKE_SNAP_RC=1 run clean
check "clean without a swap succeeds" test "$rc" = 0
check "clean without a swap: stray sysext removed" test "$(ls "$EXT")" = k3s-v1.36.4+k3s1-x86-64.raw
check "clean without a swap: no destroy" test -z "$(grep '^zfs destroy' "$calls" || true)"

swapped; run rollback; run clean
check "clean while rollback pending: exit 2" test "$rc" = 2
check "clean while rollback pending: state kept" test -e "$STATE/server"

# --- review fixes ------------------------------------------------------------------
# A copy that dies halfway must never replace the real datastore.
seed; FAKE_CP_FAIL=1 run to v1.37.1+k3s1 "$SHA"
check "copy fails: exit 1" test "$rc" = 1
check "copy fails: no complete backup" test ! -e "$STATE/backed-up"
check "copy fails: names rollback" contains "$out" "k3s-swap rollback"
: >"$calls"; run rollback
check "rollback after a failed copy succeeds" test "$rc" = 0
check "rollback after a failed copy: nothing to undo, no reboot" contains "$out" "nothing had changed"
check "rollback after a failed copy: k3s started, not masked" in_order "systemctl start k3s"
check "rollback after a failed copy: no mask" test -z "$(grep -x 'systemctl mask k3s' "$calls" || true)"
check "rollback after a failed copy: datastore untouched" test "$(cat "$DB")" = "datastore before"
check "rollback after a failed copy: symlink unchanged" test "$(readlink "$LINK")" = /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw
check "rollback after a failed copy: state gone" test ! -e "$STATE"

# A rollback-finish that times out can be run again, even with k3s running.
swapped; run rollback
FAKE_KUBELET=v1.37.1+k3s1 K3S_SWAP_TIMEOUT=0 run rollback-finish
check "finish times out: exit 1" test "$rc" = 1
check "finish times out: datastore already restored" test "$(cat "$DB")" = "datastore before"
FAKE_ACTIVE=0 FAKE_KUBELET=v1.36.4+k3s1 run rollback-finish
check "finish again after a timeout succeeds" test "$rc" = 0
check "finish again: state gone" test ! -e "$STATE"

# clean keeps an unfinished swap unless told otherwise.
seed; FAKE_KUBELET=v1.36.4+k3s1 K3S_SWAP_TIMEOUT=0 run to v1.37.1+k3s1 "$SHA"
run clean
check "clean after an unfinished swap: exit 2" test "$rc" = 2
check "clean after an unfinished swap: backup kept" test -e "$STATE/server"
check "clean after an unfinished swap: says how" contains "$out" "clean --incomplete"
FAKE_ACTIVE=0 run clean --incomplete
check "clean --incomplete succeeds" test "$rc" = 0
check "clean --incomplete: state gone" test ! -e "$STATE"

# The rollback reboot would also boot a staged Flatcar update.
swapped; FAKE_UE_STATUS=CURRENT_OP=UPDATE_STATUS_UPDATED_NEED_REBOOT run rollback
check "rollback warns about a staged Flatcar update" contains "$out" "Flatcar update is staged"
swapped; run rollback
check "rollback quiet without a staged update" test -z "$(grep 'Flatcar update' <<<"$out" || true)"

finish
