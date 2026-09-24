#!/usr/bin/env bash
# nuc26 builds from .env.example into a temp dir and leaves servers/nuc26/ alone.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

before="$(cd "$REPO_ROOT/servers/nuc26" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
ign="$(build_example nuc26)"
after="$(cd "$REPO_ROOT/servers/nuc26" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"

check "ign written outside the repo" test -s "$ign"
check "servers/nuc26/ untouched by a test build" test "$before" = "$after"
check "hostname comes from .env.example" test "$(ign_file "$ign" /etc/hostname)" = nuc26

# A stray ENV_FILE / OUT_DIR in the caller's environment must never steer a build.
stray="$(mktemp -d)"
err="$(ENV_FILE=/nonexistent/stray.env OUT_DIR="$stray" BUTANE_OUT_DIR="$stray" "$REPO_ROOT/build.sh" nuc26 2>&1 >/dev/null || true)"
check "stray ENV_FILE ignored" test -z "$(grep -F /nonexistent/stray.env <<<"$err" || true)"
rm -rf "$stray"

finish
