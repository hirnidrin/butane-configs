#!/usr/bin/env bash
#
# Build the Ignition config for one server out of a frame + reusable snippets.
#
#   ./build.sh nuc26            # or: servers/nuc26, servers/nuc26/
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
ENV_FILE="$SERVER_DIR/.env"
STAGE="$SERVER_DIR/.build"
BUTANE_OUT="$SERVER_DIR/$SERVER.butane"
IGN_OUT="$SERVER_DIR/$SERVER.ign"

[ -d "$SERVER_DIR" ] || die "no such server: servers/$SERVER"
[ -f "$MANIFEST" ] || die "missing servers/$SERVER/server.yaml"
[ -f "$ENV_FILE" ] || die "missing servers/$SERVER/.env - copy .env.example and fill in real values"

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
yq eval-all '. as $item ireduce ({}; . *+ $item) | del(.snippets)' \
	"${SNIPPET_YAMLS[@]}" "$MANIFEST" >"$STAGE/merged.yaml"

# --- 5. substitute ----------------------------------------------------------

envsubst "$SHELL_FORMAT" <"$STAGE/merged.yaml" >"$BUTANE_OUT"

leftovers="$(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' -r "$BUTANE_OUT" "$STAGE/files" | sort -u || true)"
if [ -n "$leftovers" ]; then
	echo "error: unsubstituted variables - add them to servers/$SERVER/.env:" >&2
	echo "$leftovers" | sed 's/^/  /' >&2
	exit 1
fi

# --- 6. transpile -----------------------------------------------------------

butane --strict --files-dir "$STAGE/files" <"$BUTANE_OUT" >"$IGN_OUT"

echo "built $IGN_OUT  (from ${#SNIPPETS[@]} snippets: ${SNIPPETS[*]})"
