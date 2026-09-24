#!/usr/bin/env bash
#
# Build the Ignition config for one server out of a frame + reusable snippets.
#
#   ./build.sh nuc26            # or: servers/nuc26, servers/nuc26/
#   BUTANE_ENV_FILE=… BUTANE_OUT_DIR=… ./build.sh nuc26   # build elsewhere (tests/)
#
# Pipeline:
#   1. read servers/<name>/server.yaml    - frame + list of snippets
#   2. collect vars: each snippet's defaults.env, then the server's .env (wins)
#   3. stage snippet payload files, substituting vars, into .build/files/
#   4. deep-merge snippet.yaml fragments + frame  (yq, arrays append)
#   5. substitute vars into the merged config    -> <name>.butane
#   6. transpile                                 -> <name>.ign
#
set -euo pipefail
shopt -s globstar nullglob

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

for tool in yq butane envsubst; do
	command -v "$tool" >/dev/null || die "'$tool' not found in PATH"
done

[ $# -eq 1 ] || die "usage: $(basename "$0") <server>"

# Accept nuc26, servers/nuc26 and servers/nuc26/ alike
SERVER="${1%/}"
SERVER="${SERVER#servers/}"
SERVER_DIR="$REPO_ROOT/servers/$SERVER"
MANIFEST="$SERVER_DIR/server.yaml"
# BUTANE_ENV_FILE and BUTANE_OUT_DIR may be set by the caller; the tests build
# from .env.example into a temp dir so they can never clobber a real build.
# Deliberately not plain ENV_FILE / OUT_DIR: a stray variable of that common
# name in the caller's shell must never steer a real build.
ENV_FILE="${BUTANE_ENV_FILE:-$SERVER_DIR/.env}"
OUT_DIR="${BUTANE_OUT_DIR:-$SERVER_DIR}"
STAGE="$OUT_DIR/.build"
BUTANE_OUT="$OUT_DIR/$SERVER.butane"
IGN_OUT="$OUT_DIR/$SERVER.ign"

[ -d "$SERVER_DIR" ] || die "no such server: servers/$SERVER"
[ -f "$MANIFEST" ] || die "missing servers/$SERVER/server.yaml"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE - copy .env.example and fill in real values"

# --- 1. snippets ------------------------------------------------------------

mapfile -t SNIPPETS < <(yq -r '.snippets[]' "$MANIFEST")
[ ${#SNIPPETS[@]} -gt 0 ] || die "$MANIFEST lists no snippets"

SNIPPET_YAMLS=()
for name in "${SNIPPETS[@]}"; do
	[ -f "$REPO_ROOT/snippets/$name/snippet.yaml" ] || die "unknown snippet '$name' (no snippets/$name/snippet.yaml)"
	SNIPPET_YAMLS+=("$REPO_ROOT/snippets/$name/snippet.yaml")
done

# --- 2. variables -----------------------------------------------------------

# Snippet defaults first, server .env last so it always wins.
ENV_FILES=()
for name in "${SNIPPETS[@]}"; do
	[ -f "$REPO_ROOT/snippets/$name/defaults.env" ] && ENV_FILES+=("$REPO_ROOT/snippets/$name/defaults.env")
done
ENV_FILES+=("$ENV_FILE")

set -a
for f in "${ENV_FILES[@]}"; do
	# shellcheck disable=SC1090
	. "$f"
done
set +a

# Substitute only the names we actually know about, so that ${...} in shell
# scripts, Caddyfiles and the like survives untouched.
VAR_NAMES="$(grep -hoE '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILES[@]}" | tr -d '=' | sort -u)"
# shellcheck disable=SC2016,SC2086 # literal ${NAME} wanted; VAR_NAMES is split on purpose
SHELL_FORMAT="$(printf '${%s} ' $VAR_NAMES)"

# --- 3. stage payload files -------------------------------------------------

case "$STAGE" in
*/.build) rm -rf "$STAGE" ;;
*) die "refusing to clean unexpected staging path: $STAGE" ;;
esac
mkdir -p "$STAGE/files"

stage_tree() {
	local root="$1" src rel
	[ -d "$root" ] || return 0
	for src in "$root"/**/*; do
		[ -f "$src" ] || continue
		rel="${src#"$root"/}"
		mkdir -p "$STAGE/files/$(dirname "$rel")"
		envsubst "$SHELL_FORMAT" <"$src" >"$STAGE/files/$rel"
	done
}

for name in "${SNIPPETS[@]}"; do
	stage_tree "$REPO_ROOT/snippets/$name/files"
done
# A server may shadow any snippet payload file with its own copy.
stage_tree "$SERVER_DIR/files"

# --- 4. merge ---------------------------------------------------------------

# '*+' deep-merges maps and appends arrays, so storage.files / systemd.units
# from several snippets concatenate. The frame is merged last: its scalars win.
# shellcheck disable=SC2016 # $item is a yq variable, not a shell one
yq eval-all '. as $item ireduce ({}; . *+ $item) | del(.snippets)' \
	"${SNIPPET_YAMLS[@]}" "$MANIFEST" >"$STAGE/merged.yaml"

# --- 5. substitute ----------------------------------------------------------

envsubst "$SHELL_FORMAT" <"$STAGE/merged.yaml" >"$BUTANE_OUT"

leftovers="$(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' -r "$BUTANE_OUT" "$STAGE/files" | sort -u || true)"
if [ -n "$leftovers" ]; then
	echo "error: unsubstituted variables - add them to servers/$SERVER/.env:" >&2
	# shellcheck disable=SC2001 # indent every line; sed is clearer than a loop
	echo "$leftovers" | sed 's/^/  /' >&2
	exit 1
fi

# --- 6. transpile -----------------------------------------------------------

butane --strict --files-dir "$STAGE/files" <"$BUTANE_OUT" >"$IGN_OUT"

echo "built $IGN_OUT  (from ${#SNIPPETS[@]} snippets: ${SNIPPETS[*]})"
