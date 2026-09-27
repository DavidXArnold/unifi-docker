#!/usr/bin/env bash
# Shared helpers for the container tests. Source this file.

DOCKER="${DOCKER:-docker}"
TIMEOUT="${TIMEOUT:-300}"

fail() {
    echo "::error::$*"
    return 1
}

# Remove a test container together with its anonymous volumes (the image
# declares VOLUMEs, so each run would otherwise leave a MongoDB behind).
cleanup_container() {
    "${DOCKER}" rm -f -v "$1" >/dev/null 2>&1 || true
}

dump_logs() {
    local ctr="$1"
    echo "--- container log (${ctr}) ---"
    "${DOCKER}" logs "${ctr}" 2>&1 | tail -40
    echo "--- server.log (${ctr}) ---"
    "${DOCKER}" exec "${ctr}" tail -40 /unifi/log/server.log 2>/dev/null || true
}

# Wait until the controller answers on its HTTPS port.
wait_for_controller() {
    local ctr="$1"
    local start=${SECONDS}
    while (( SECONDS - start < TIMEOUT )); do
        if [ "$("${DOCKER}" inspect -f '{{.State.Running}}' "${ctr}" 2>/dev/null)" != "true" ]; then
            dump_logs "${ctr}"
            fail "${ctr}: container exited before the controller came up"
            return 1
        fi
        if "${DOCKER}" exec "${ctr}" /usr/local/bin/docker-healthcheck.sh >/dev/null 2>&1; then
            echo "${ctr}: controller up after $(( SECONDS - start ))s"
            return 0
        fi
        sleep 5
    done
    dump_logs "${ctr}"
    fail "${ctr}: controller not up after ${TIMEOUT}s"
}

# Run a command in a throwaway container of IMAGE with VOLUME mounted on /unifi.
in_volume() {
    local image="$1" volume="$2"; shift 2
    "${DOCKER}" run --rm -v "${volume}:/unifi" --entrypoint bash "${image}" -c "$*"
}

# Stop a container and check that both UniFi and its MongoDB shut down cleanly.
assert_clean_shutdown() {
    local image="$1" ctr="$2" volume="$3"
    "${DOCKER}" stop -t 60 "${ctr}" >/dev/null
    local code
    code=$("${DOCKER}" inspect -f '{{.State.ExitCode}}' "${ctr}")
    [ "${code}" = "0" ] || { dump_logs "${ctr}"; fail "${ctr}: exited with code ${code} on stop"; return 1; }
    in_volume "${image}" "${volume}" 'grep -q "shutting down with code:0" /unifi/log/mongod.log' \
        || { fail "${ctr}: MongoDB did not shut down cleanly"; return 1; }
    echo "${ctr}: clean shutdown"
}
