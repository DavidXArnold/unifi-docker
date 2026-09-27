#!/usr/bin/env bash
# Installs the UniFi Network Application and its runtime into the image.
# Bind-mounted by the Dockerfile at build time, so it never ends up in the image.

set -euo pipefail

PKGURL="${1:?usage: docker-build.sh PKGURL}"
ARCH="$(dpkg --print-architecture)"

# Keep files the controller never uses out of the image. dpkg skips these paths
# for every package installed below, so they are never written to the layer.
case "${ARCH}" in
    amd64) OTHER_NATIVE=aarch64 ;;
    arm64) OTHER_NATIVE=x86_64 ;;
    *)     OTHER_NATIVE=none ;;
esac
cat > /etc/dpkg/dpkg.cfg.d/01-unifi-docker-excludes <<EOF
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/bin/mongoperf
path-exclude=/usr/bin/mongos
path-exclude=/usr/lib/unifi/lib/native/Linux/${OTHER_NATIVE}/*
EOF
# Some JRE postinst scripts expect this to exist
mkdir -p /usr/share/man/man1

apt-get update
apt-get install -qy --no-install-recommends \
    ca-certificates \
    curl \
    gosu \
    libcap2-bin \
    procps \
    tzdata

# UniFi pins a specific Java release (the updater workflow keeps the temurin
# package below in step with it), so pull the JRE from Eclipse Adoptium.
# 20.04 is kept as the base because it is the last Ubuntu release that packages
# mongodb-server, which the UniFi package depends on.
mkdir -p /etc/apt/keyrings
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o /etc/apt/keyrings/adoptium.asc
echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
    > /etc/apt/sources.list.d/adoptium.list
apt-get update

curl -fsSL -o /tmp/unifi.deb "${PKGURL}"
apt-get install -qy --no-install-recommends temurin-25-jre /tmp/unifi.deb
rm -f /tmp/unifi.deb
chown -R unifi:unifi /usr/lib/unifi

apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/apt /var/log/dpkg.log /var/cache/debconf/*-old /tmp/hsperfdata_*

rm -rf ${ODATADIR} ${OLOGDIR} ${ORUNDIR} ${BASEDIR}/data ${BASEDIR}/run ${BASEDIR}/logs
mkdir -p ${DATADIR} ${LOGDIR} ${RUNDIR}
ln -s ${DATADIR} ${BASEDIR}/data
ln -s ${RUNDIR} ${BASEDIR}/run
ln -s ${LOGDIR} ${BASEDIR}/logs
ln -s ${DATADIR} ${ODATADIR}
ln -s ${LOGDIR} ${OLOGDIR}
ln -s ${RUNDIR} ${ORUNDIR}
mkdir -p /var/cert ${CERTDIR}
ln -s ${CERTDIR} /var/cert/unifi

mkdir -p /usr/unifi/init.d /usr/local/unifi/init.d
chown -R unifi:unifi /unifi
