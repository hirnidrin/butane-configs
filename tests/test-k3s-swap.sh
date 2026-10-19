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

finish
