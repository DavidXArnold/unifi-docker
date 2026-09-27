#!/usr/bin/env bash
# Upgrade test: run FROM_IMAGE on a fresh volume, then start IMAGE on the same
# volume and check the controller comes up and migrates the database.
# Usage: tests/upgrade-test.sh FROM_IMAGE IMAGE

set -euo pipefail

FROM_IMAGE="${1:?usage: upgrade-test.sh FROM_IMAGE IMAGE}"
IMAGE="${2:?usage: upgrade-test.sh FROM_IMAGE IMAGE}"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

vol="unifi-upgrade"
old="unifi-upgrade-from"
new="unifi-upgrade-to"

cleanup() {
    cleanup_container "${old}"
    cleanup_container "${new}"
    "${DOCKER}" volume rm "${vol}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

"${DOCKER}" run -d --name "${old}" -v "${vol}:/unifi" "${FROM_IMAGE}" >/dev/null
wait_for_controller "${old}"
"${DOCKER}" stop -t 60 "${old}" >/dev/null
from_version=$(in_volume "${IMAGE}" "${vol}" 'cat /unifi/data/db/version')
echo "${FROM_IMAGE}: created database at version ${from_version}"

"${DOCKER}" run -d --name "${new}" -v "${vol}:/unifi" "${IMAGE}" >/dev/null
wait_for_controller "${new}"

want=$("${DOCKER}" run --rm --entrypoint dpkg-query "${IMAGE}" -W -f '${Version}' unifi | cut -d- -f1)
got=$("${DOCKER}" exec "${new}" cat /unifi/data/db/version)
[ "${got}" = "${want}" ] || { dump_logs "${new}"; fail "database is at ${got}, expected ${want}"; exit 1; }
echo "${IMAGE}: migrated database ${from_version} -> ${got}"

assert_clean_shutdown "${IMAGE}" "${new}" "${vol}"
echo "Upgrade test passed"
