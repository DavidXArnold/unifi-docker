#!/usr/bin/env bash
# Start the image in each supported run mode and wait for the controller UI to answer.
# Usage: smoke-test.sh IMAGE [TIMEOUT_SECONDS]

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh IMAGE [TIMEOUT_SECONDS]}"
TIMEOUT="${2:-300}"
DOCKER="${DOCKER:-docker}"

run_mode() {
    local name="$1"; shift
    local ctr="unifi-smoke-${name}"
    "${DOCKER}" rm -f -v "${ctr}" >/dev/null 2>&1 || true
    "${DOCKER}" run -d --name "${ctr}" "$@" "${IMAGE}" >/dev/null

    local start=${SECONDS}
    while (( SECONDS - start < TIMEOUT )); do
        if [ "$("${DOCKER}" inspect -f '{{.State.Running}}' "${ctr}")" != "true" ]; then
            echo "::error::${name}: container exited"
            "${DOCKER}" logs "${ctr}" 2>&1 | tail -50
            return 1
        fi
        if "${DOCKER}" exec "${ctr}" /usr/local/bin/docker-healthcheck.sh >/dev/null 2>&1; then
            echo "${name}: controller up after $(( SECONDS - start ))s"
            "${DOCKER}" rm -f -v "${ctr}" >/dev/null
            return 0
        fi
        sleep 5
    done

    echo "::error::${name}: controller not up after ${TIMEOUT}s"
    "${DOCKER}" logs "${ctr}" 2>&1 | tail -50
    "${DOCKER}" exec "${ctr}" tail -50 /unifi/log/server.log 2>/dev/null || true
    return 1
}

run_mode root
run_mode gosu -e RUNAS_UID0=false
run_mode user --user unifi
