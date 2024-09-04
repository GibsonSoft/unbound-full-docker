# syntax=docker/dockerfile:1.9.0

# DL3018: We're specifying pkgs via ARGs + want latest security updates if possible. 
#         Will pin if there are any future issues.
# SC2086: Not needed in the majority of cases here (like apk calls that expect a list of pkgs, not a string).
# DL3020: A bug maybe? All these appear for ARGs with URLs in ADD statements.
# DL3003: Not splitting up RUNs just to cd.
# hadolint global ignore=DL3018,SC2086,DL3020,DL3003

ARG ALPINE_VERSION=latest
ARG XX_VERSION=latest

FROM --platform=${BUILDPLATFORM} tonistiigi/xx:${XX_VERSION} AS xx
FROM --platform=${BUILDPLATFORM} alpine:${ALPINE_VERSION} AS core-base
ARG CORE_BUILD_DEPS
ENV CORE_BUILD_DEPS=${CORE_BUILD_DEPS}

ENV CC="xx-clang"
ENV CXX="xx-clang++"
ENV CFLAGS="-B/usr/bin/llvm"
ENV CXXFLAGS="-B/usr/bin/llvm"
ENV LDFLAGS="--fuse-ld=lld --rtlib=compiler-rt --unwindlib=libunwind"

WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]

COPY --from=xx / /

RUN <<EOF
    apk --no-cache upgrade 
    apk add --no-cache ${CORE_BUILD_DEPS}
    mkdir /usr/bin/llvm
    cd /usr/bin/llvm || exit
    ln -s ../lld lld
    ln -s ../llvm-ar ar
    ln -s ../llvm-objcopy objcopy
    ln -s ../llvm-objdump objdump
    ln -s ../llvm-ranlib ranlib
    ln -s ../llvm-strings string
EOF



FROM scratch AS sources
WORKDIR /tmp/src
ARG OPENSSL_SHA256
ARG OPENSSL_SOURCE
ARG OPENSSL_VERSION
ARG OPENSSL_SOURCE_FILE=openssl-${OPENSSL_VERSION}.tar.gz
ARG OPENSSL_DOWNLOAD_URL=${OPENSSL_SOURCE}/${OPENSSL_SOURCE_FILE}
ADD --checksum=sha256:${OPENSSL_SHA256} ${OPENSSL_DOWNLOAD_URL} openssl.tar.gz
ADD ${OPENSSL_DOWNLOAD_URL}.asc openssl.tar.gz.asc

ARG UNBOUND_SHA256
ARG UNBOUND_SOURCE
ARG UNBOUND_VERSION
ARG UNBOUND_SOURCE_FILE=unbound-${UNBOUND_VERSION}.tar.gz
ARG UNBOUND_DOWNLOAD_URL=${UNBOUND_SOURCE}/${UNBOUND_SOURCE_FILE}
ADD --checksum=sha256:${UNBOUND_SHA256} ${UNBOUND_DOWNLOAD_URL} unbound.tar.gz

ARG LDNS_SHA256
ARG LDNS_SOURCE
ARG LDNS_VERSION
ARG LDNS_SOURCE_FILE=ldns-${LDNS_VERSION}.tar.gz
ARG LDNS_DOWNLOAD_URL=${LDNS_SOURCE}/${LDNS_SOURCE_FILE}
ADD --checksum=sha256:${LDNS_SHA256} ${LDNS_DOWNLOAD_URL} ldns.tar.gz

ARG PROTOBUFC_SHA256
ARG PROTOBUFC_SOURCE
ARG PROTOBUFC_VERSION
ARG PROTOBUFC_SOURCE_FILE=protobuf-c-${PROTOBUFC_VERSION}.tar.gz
ARG PROTOBUFC_DOWNLOAD_URL=${PROTOBUFC_SOURCE}/v${PROTOBUFC_VERSION}/${PROTOBUFC_SOURCE_FILE}
ADD --checksum=sha256:${PROTOBUFC_SHA256} ${PROTOBUFC_DOWNLOAD_URL} protobuf-c.tar.gz



FROM core-base AS target-base
WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]
ARG TARGETPLATFORM
ARG TARGET_BUILD_DEPS

RUN <<EOF
    xx-info env # Prevent docker build bug that spams console when apk line w/ variable is first
    xx-apk add --no-cache ${TARGET_BUILD_DEPS}
    ln -s "$(xx-info sysroot)"usr/lib/libunwind.so.1 "$(xx-info sysroot)"usr/lib/libunwind.so
EOF



FROM target-base as protobuf-c
WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]

COPY --from=sources /tmp/src/protobuf-c.tar.gz /tmp/src/protobuf-c.tar.gz

RUN <<EOF
    mkdir ./protobuf-c-src
    xx-apk add --no-cache --virtual build-deps ${PROTOBUFC_BUILD_DEPS}
    tar -xzf protobuf-c.tar.gz --strip-components=1 -C ./protobuf-c-src
    cd protobuf-c-src || exit

    ./configure CC=clang CXX=clang++ --prefix=/opt/protobuf-c
    make -j
    make -j install
    cp /opt/protobuf-c/bin/protoc-c ./protoc-c
    make clean

    ./configure --prefix=/opt/protobuf-c
    make -j
    make -j install
    cp ./protoc-c /opt/protobuf-c/bin/protoc-c

    rm -rf /tmp/*
    xx-apk del build-deps ${TARGET_BUILD_DEPS}
    apk del ${CORE_BUILD_DEPS}
EOF



FROM target-base AS openssl
WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]

ARG OPENSSL_BUILD_DEPS
ARG OPENSSL_OPGP_KEYS

COPY --from=sources /tmp/src/openssl.tar.gz /tmp/src/openssl.tar.gz.asc /tmp/src/

RUN <<EOF
    GNUPGHOME="$(mktemp -d)"
    export GNUPGHOME
    xx-apk add --no-cache --virtual build-deps ${OPENSSL_BUILD_DEPS}
    gpg --no-tty --keyserver keyserver.ubuntu.com --recv-keys ${OPENSSL_OPGP_KEYS}
    gpg --batch --verify openssl.tar.gz.asc openssl.tar.gz
    mkdir ./openssl-src
    tar -xzf openssl.tar.gz --strip-components=1 -C ./openssl-src
    rm -f openssl.tar.gz openssl.tar.gz.asc
    cd ./openssl-src || exit

    ./Configure $(xx-info os)-$(xx-info march) \
        --prefix=/opt/openssl \
        --openssldir=/opt/openssl \
        no-ssl3 \
        no-docs \
        no-tests \
        no-filenames \
        no-legacy \
        no-shared \
        no-pinshared \
        enable-ec_nistp_64_gcc_128 \
        -static
    make -j
    make -j install_sw
    xx-apk del build-deps ${TARGET_BUILD_DEPS}
    apk del ${CORE_BUILD_DEPS}
    rm -rf /tmp/*
EOF



FROM target-base AS unbound
WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]

ARG UNBOUND_BUILD_DEPS

COPY --from=sources /tmp/src/unbound.tar.gz /tmp/src/unbound.tar.gz
COPY --from=openssl /opt/openssl /opt/openssl

# Ignore SC2034, Needed to static-compile unbound/ldns, per https://github.com/NLnetLabs/unbound/issues/91#issuecomment-1707544943
# hadolint ignore=SC2034
RUN <<EOF
    mkdir ./unbound-src
    xx-apk add --no-cache --virtual build-deps ${UNBOUND_BUILD_DEPS}
    tar -xzf unbound.tar.gz --strip-components=1 -C ./unbound-src
    rm -f unbound.tar.gz
    cd ./unbound-src || exit
    addgroup -S _unbound
    adduser -S -s /dev/null -h /etc/unbound -G _unbound _unbound
    
    sed -e 's/@LDFLAGS@/@LDFLAGS@ -all-static/' -i Makefile.in
    LIBS="-lpthread -lm"
    LDFLAGS="-Wl,-static -static -static-libgcc"
    QEMU_LD_PREFIX=$(xx-info sysroot)
    export QEMU_LD_PREFIX
    ./configure \
        --host=$(xx-clang --print-target-triple) \
        --prefix= \
        --with-chroot-dir=/var/chroot/unbound \
        --with-pidfile=/var/chroot/unbound/var/run/unbound.pid \
        --with-rootkey-file=/var/root.key \
        --with-rootcert-file=/var/icannbundle.pem \
        --with-pthreads \
        --with-username=_unbound \
        --with-ssl=/opt/openssl \
        --with-libevent=$(xx-info sysroot)usr/ \
        --with-libexpat=$(xx-info sysroot)usr/ \
        --with-libnghttp2=$(xx-info sysroot)usr/ \
        --with-libhiredis=$(xx-info sysroot)usr/ \
        --with-libsodium=$(xx-info sysroot)usr/ \
        --with-protobuf-c=$(xx-info sysroot)usr/ \
        --enable-dnstap \
        --enable-tfo-server \
        --enable-tfo-client \
        --enable-event-api \
        --enable-subnet \
        --enable-cachedb \
        --enable-dnscrypt \
        --disable-flto \
        --disable-shared \
        --disable-static \
        --enable-fully-static \
        --disable-rpath
    make -j install
    mv /etc/unbound/unbound.conf /etc/unbound/unbound.conf.example
    xx-apk del build-deps ${TARGET_BUILD_DEPS}
    apk del ${CORE_BUILD_DEPS}
    rm -rf /tmp/*
EOF



FROM target-base AS ldns
WORKDIR /tmp/src
SHELL ["/bin/ash", "-cexo", "pipefail"]
ARG TARGETPLATFORM

ARG LDNS_BUILD_DEPS

COPY --from=sources /tmp/src/ldns.tar.gz /tmp/src/ldns.tar.gz
COPY --from=openssl /opt/openssl /opt/openssl

# Ignore SC2034, Needed to static-compile unbound/ldns, per https://github.com/NLnetLabs/unbound/issues/91#issuecomment-1707544943
# hadolint ignore=SC2034
RUN <<EOF
    mkdir ./ldns-src
    xx-apk add --no-cache --virtual build-deps ${LDNS_BUILD_DEPS}
    tar -xzf ldns.tar.gz --strip-components=1 -C ./ldns-src
    rm -f ldns.tar.gz
    cd ./ldns-src || exit
    
    sed -e 's/@LDFLAGS@/@LDFLAGS@ -all-static/' -i Makefile.in
    LIBS="-lpthread -lm"
    LDFLAGS="-Wl,-static -static -static-libgcc"
    ./configure \
        --host=$(xx-clang --print-target-triple) \
        --prefix=/opt/ldns \
        --with-ssl=/opt/openssl \
        --with-drill \
        --disable-shared \
        --enable-static
    make -j
    make -j install
    xx-apk del build-deps ${TARGET_BUILD_DEPS}
    apk del ${CORE_BUILD_DEPS}
    rm -rf /tmp/*
EOF



FROM scratch AS final
WORKDIR /
SHELL ["/bin/ash", "-cexo", "pipefail"]
ENV PATH="/bin:/sbin"
ARG ROOT_HINTS
ARG ICANN_CERT

ADD ${ROOT_HINTS} /var/chroot/unbound/var/unbound/root.hints
ADD ${ICANN_CERT} /var/chroot/unbound/var/unbound/icannbundle.pem

COPY ./data/etc/ /var/chroot/unbound/etc/
COPY --chmod=744 ./data/unbound.bootstrap /unbound

COPY --from=target-base /bin/busybox /lib/ld-musl*.so.1 /lib/
COPY --from=target-base /etc/ssl/certs/ /etc/ssl/certs/

COPY --from=openssl /opt/openssl/bin/openssl /bin/openssl

COPY --from=ldns /opt/ldns/bin/drill /bin/drill

COPY --from=unbound /sbin/unbound* /sbin/
COPY --from=unbound /etc/unbound/ /var/chroot/unbound/etc/unbound/
COPY --from=unbound /etc/passwd /etc/group /etc/

RUN ["/lib/busybox", "ln", "-s", "/lib/busybox", "/bin/ash"]
RUN <<EOF
    SH_CMDS="ln sed grep chmod chown mkdir cp awk uniq bc rm find nproc sh cat mv"
    
    for link in ${SH_CMDS}; do
        /lib/busybox ln -s /lib/busybox /bin/${link}
    done

    ln -s /var/chroot/unbound/var/unbound/ /var/unbound
    ln -s /var/chroot/unbound/etc/unbound/ /etc/unbound

    mkdir -p /var/chroot/unbound/var/run/
    mkdir -p /var/chroot/unbound/dev/
    cp -a /dev/random /dev/urandom /dev/null /var/chroot/unbound/dev/
EOF

EXPOSE 53/tcp
EXPOSE 53/udp

HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 CMD ["/bin/drill", "@127.0.0.1", "cloudflare.com"]
ENTRYPOINT ["/unbound", "-d"]
CMD ["-c", "/etc/unbound/unbound.conf"]