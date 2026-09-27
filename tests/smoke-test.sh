#!/usr/bin/env bash
# Container tests for a built image: image contents, every supported run mode
# (including a clean shutdown), and certificate import.
# Usage: tests/smoke-test.sh IMAGE

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh IMAGE}"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

test_image_contents() {
    "${DOCKER}" run --rm -i --entrypoint bash "${IMAGE}" <<'EOF'
set -euo pipefail
err() { echo "::error::image: $*"; exit 1; }

# permset must stay setuid root, or --user unifi can't fix volume ownership
[ "$(stat -c '%U %a' /usr/local/bin/permset)" = "root 4755" ] || err "permset is not setuid root"

# The entrypoint's JAVA_HOME is what setcap is applied to in RUNAS_UID0=false mode
. /usr/unifi/functions
set_java_home
[ -f "${JAVA_HOME}/bin/java" ] || err "JAVA_HOME (${JAVA_HOME}) has no bin/java"

# The JRE must be the Java release the UniFi package depends on
want=$(dpkg-query -W -f '${Depends}' unifi | grep -oE 'temurin-[0-9]+-jre' | grep -oE '[0-9]+' | head -1)
have=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d. -f1)
[ "${want}" = "${have}" ] || err "UniFi depends on Java ${want} but the image runs Java ${have}"

for cmd in mongod mongo keytool openssl gosu setcap curl pgrep; do
    command -v "${cmd}" >/dev/null || err "${cmd} is missing"
done
for f in /usr/bin/mongos /usr/bin/mongoperf /usr/local/bin/docker-build.sh; do
    [ ! -e "${f}" ] || err "${f} should not be in the image"
done

validate >/dev/null || err "hotfix validation failed"
echo "image contents: ok"
EOF
}

# Start the controller with the given docker run options, wait for it, then stop it.
test_run_mode() {
    local name="$1"; shift
    local ctr="unifi-smoke-${name}" vol="unifi-smoke-${name}"
    cleanup_container "${ctr}"
    "${DOCKER}" volume rm "${vol}" >/dev/null 2>&1 || true

    "${DOCKER}" run -d --name "${ctr}" -v "${vol}:/unifi" "$@" "${IMAGE}" >/dev/null
    wait_for_controller "${ctr}"
    assert_clean_shutdown "${IMAGE}" "${ctr}" "${vol}"

    cleanup_container "${ctr}"
    "${DOCKER}" volume rm "${vol}" >/dev/null
}

# import_cert should load a mounted certificate and its chain into the keystore.
test_cert_import() {
    local ctr="unifi-smoke-cert" vol="unifi-smoke-cert"
    cleanup_container "${ctr}"
    "${DOCKER}" volume rm "${vol}" >/dev/null 2>&1 || true

    in_volume "${IMAGE}" "${vol}" '
        set -e
        cd /unifi/cert
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Smoke Test CA" \
            -keyout ca.key -out chain.pem 2>/dev/null
        openssl req -newkey rsa:2048 -nodes -subj "/CN=unifi.smoke.test" \
            -keyout privkey.pem -out leaf.csr 2>/dev/null
        openssl x509 -req -in leaf.csr -CA chain.pem -CAkey ca.key -CAcreateserial \
            -days 2 -out cert.pem 2>/dev/null
        rm -f ca.key leaf.csr chain.srl'

    "${DOCKER}" run -d --name "${ctr}" -v "${vol}:/unifi" "${IMAGE}" >/dev/null
    wait_for_controller "${ctr}"

    local served
    served=$("${DOCKER}" exec "${ctr}" bash -c \
        'openssl s_client -connect localhost:8443 -showcerts </dev/null 2>/dev/null')
    grep -qE 'subject=.*CN ?= ?unifi\.smoke\.test' <<< "${served}" \
        || { dump_logs "${ctr}"; fail "cert: controller is not serving the imported certificate"; return 1; }
    [ "$(grep -c 'BEGIN CERTIFICATE' <<< "${served}")" -ge 2 ] \
        || { fail "cert: controller is not serving the certificate chain"; return 1; }
    echo "${ctr}: serving imported certificate and chain"

    cleanup_container "${ctr}"
    "${DOCKER}" volume rm "${vol}" >/dev/null
}

test_image_contents
test_run_mode root
test_run_mode gosu -e RUNAS_UID0=false
test_run_mode user --user unifi
test_cert_import
echo "All smoke tests passed"
