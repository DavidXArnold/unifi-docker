# syntax=docker/dockerfile:1

# Cross-compiled on the build host, so multi-arch builds don't run Go under emulation
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS permset
ARG TARGETOS TARGETARCH
ARG PERMSET_REF=590a2e6c219db3304240ebb2d9cadfaf31400c3b
WORKDIR /src
RUN git init -q . && \
    git fetch -q --depth 1 https://github.com/jacobalberty/permset.git "${PERMSET_REF}" && \
    git checkout -q FETCH_HEAD && \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.chownDir=/unifi" -o /out/permset && \
    chmod 4755 /out/permset

FROM ubuntu:20.04

LABEL maintainer="Jacob Alberty <jacob.alberty@foundigital.com>"

ARG DEBIAN_FRONTEND=noninteractive

ARG PKGURL=https://dl.ui.com/unifi/10.6.106/unifi_sysvinit_all.deb

ENV BASEDIR=/usr/lib/unifi \
    DATADIR=/unifi/data \
    LOGDIR=/unifi/log \
    CERTDIR=/unifi/cert \
    RUNDIR=/unifi/run \
    ORUNDIR=/var/run/unifi \
    ODATADIR=/var/lib/unifi \
    OLOGDIR=/var/log/unifi \
    CERTNAME=cert.pem \
    CERT_PRIVATE_NAME=privkey.pem \
    CERT_IS_CHAIN=false \
    BIND_PRIV=true \
    RUNAS_UID0=true \
    UNIFI_GID=999 \
    UNIFI_UID=999

# The heavy install layer comes first so that editing the scripts below
# doesn't invalidate it.
RUN --mount=type=bind,source=docker-build.sh,target=/tmp/build/docker-build.sh \
    set -ex \
 && groupadd -r unifi -g $UNIFI_GID \
 && useradd --no-log-init -r -u $UNIFI_UID -g $UNIFI_GID unifi \
 && bash /tmp/build/docker-build.sh "${PKGURL}"

# Plain COPY keeps the setuid bit set in the build stage
COPY --from=permset /out/permset /usr/local/bin/permset
COPY --chmod=0755 docker-entrypoint.sh docker-healthcheck.sh /usr/local/bin/
COPY --chmod=0644 functions /usr/unifi/functions
COPY --chmod=0755 import_cert /usr/unifi/init.d/

# Apply any hotfixes that were included
COPY --chmod=0755 hotfixes /usr/local/unifi/hotfixes
RUN run-parts /usr/local/unifi/hotfixes

VOLUME ["/unifi", "${RUNDIR}"]

EXPOSE 6789/tcp 8080/tcp 8443/tcp 8880/tcp 8843/tcp 3478/udp 10001/udp

WORKDIR /unifi

HEALTHCHECK --start-period=5m CMD /usr/local/bin/docker-healthcheck.sh || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["unifi"]
