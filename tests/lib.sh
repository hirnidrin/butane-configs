# shellcheck shell=bash
# Shared helpers for the build tests. Source it, don't run it.
#
# Tests build a server from its committed .env.example into a temp dir and
# assert on the generated Ignition JSON. They never touch servers/<name>/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0

# build_example <server> - build from .env.example into a temp dir, print the .ign path
build_example() {
	local server="$1" out
	out="$(mktemp -d)"
	ENV_FILE="$REPO_ROOT/servers/$server/.env.example" OUT_DIR="$out" \
		"$REPO_ROOT/build.sh" "$server" >/dev/null
	echo "$out/$server.ign"
}

# ign_file <ign> <path> - decoded contents of an inline storage file
ign_file() {
	local src comp
	src="$(jq -r --arg p "$2" '.storage.files[] | select(.path == $p) | .contents.source' "$1")"
	comp="$(jq -r --arg p "$2" '.storage.files[] | select(.path == $p) | .contents.compression // ""' "$1")"
	case "$src" in
	"data:;base64,"*)
		if [ "$comp" = gzip ]; then
			printf '%s' "${src#data:;base64,}" | base64 -d | gzip -d
		else
			printf '%s' "${src#data:;base64,}" | base64 -d
		fi
		;;
	"data:,"*)
		python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.unquote(sys.argv[1]))' "${src#data:,}"
		;;
	*)
		echo "no inline file at $2" >&2
		return 1
		;;
	esac
}

# ign_remote <ign> <path> - "<source> <hash>" of a downloaded storage file
ign_remote() {
	jq -r --arg p "$2" '.storage.files[] | select(.path == $p) | "\(.contents.source) \(.contents.verification.hash)"' "$1"
}

# ign_link <ign> <path> - target of a symlink
ign_link() {
	jq -r --arg p "$2" '.storage.links[] | select(.path == $p) | .target' "$1"
}

# ign_unit <ign> <name> - contents of a systemd unit
ign_unit() {
	jq -r --arg n "$2" '.systemd.units[] | select(.name == $n) | .contents' "$1"
}

# ign_unit_enabled <ign> <name> - succeed if the unit is enabled
ign_unit_enabled() {
	jq -e --arg n "$2" '.systemd.units[] | select(.name == $n) | .enabled == true' "$1" >/dev/null
}

# ign_dropin <ign> <unit> <dropin> - contents of a unit drop-in
ign_dropin() {
	jq -r --arg n "$2" --arg d "$3" '.systemd.units[] | select(.name == $n) | .dropins[] | select(.name == $d) | .contents' "$1"
}

# check <description> <command...> - run one assertion, report, keep going
check() {
	if "${@:2}"; then
		echo "ok   - $1"
	else
		echo "FAIL - $1"
		FAILS=$((FAILS + 1))
	fi
}

contains() { grep -qF -- "$2" <<<"$1"; }

finish() {
	if [ "$FAILS" -ne 0 ]; then
		echo "$FAILS check(s) failed"
		exit 1
	fi
}
