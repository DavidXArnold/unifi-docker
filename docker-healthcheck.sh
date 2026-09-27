#!/usr/bin/env bash

SYSPROPS_FILE=${DATADIR}/system.properties
if [ -f "${SYSPROPS_FILE}" ]; then
    SYSPROPS_PORT=`grep "^unifi.https.port=" ${SYSPROPS_FILE} | cut -d'=' -f2`
fi
PORT=${SYSPROPS_PORT:-8443}

# Docker only defines exit codes 0 (healthy) and 1 (unhealthy)
curl --max-time 5 -kILs --fail "https://localhost:${PORT}" >/dev/null || exit 1
