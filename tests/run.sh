#!/usr/bin/env bash
#
# Run every tests/test-*.sh, then shellcheck every script in the repo.
# Exits non-zero if anything failed.
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

rc=0
for t in tests/test-*.sh; do
	echo "== $t"
	bash "$t" || rc=1
done

echo "== shellcheck"
mapfile -t scripts < <(find snippets -path '*/files/opt/bin/*' -type f)
shellcheck -x build.sh tests/*.sh "${scripts[@]}" || rc=1

exit $rc
