# Build context is this directory (ftemaster/) - same reasoning as
# fteqw-server/Dockerfile: fteqw itself is fetched at build time (see
# FTEQW_REF) rather than vendored into the repo, and used entirely stock.

# ftemaster is FTE's WebRTC/ICE broker AND legacy master server, built
# from the exact same fteqw source tree as fteqw-server/Dockerfile and
# nginx/Dockerfile, just via engine/Makefile's "master-rel" target
# (-DMASTERONLY, engine/Makefile:2590-2596) instead of "sv-rel" or
# "gl-rel". It relays ICE/SDP metadata so browser and native fteqw
# clients can connect to fteqw-server over WebRTC (UDP) instead of only
# WSS (TCP) - see the README's WebRTC section. It holds no game state, so
# unlike fteqw-server it needs no PAK_DIR mount at all.
ARG FTEQW_REF=2025-09-27

FROM ubuntu:24.04 AS builder
ARG FTEQW_REF

# Matches fteqw-server/Dockerfile's own build deps, trimmed to drop the
# GL/audio-only ones (gcc-multilib/g++-multilib, mesa-common-dev,
# libasound2-dev, libxcursor-dev) - master-rel links no client/gamecode
# objects (engine/Makefile's MASTER_OBJS). "makelibs" is still needed
# though: quakedef.h is shared across every object file master-rel builds
# (including the ones it does link), and pulls in headers - libpng's
# included - that only exist once makelibs has fetched+built fteqw's own
# bundled copies, same as fteqw-server/Dockerfile relies on.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential automake libtool \
        p7zip-full zip wget pkg-config libgnutls28-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src

WORKDIR /src/engine
RUN make FTE_TARGET=linux64 makelibs \
    && make -j"$(nproc)" FTE_TARGET=linux64 master-rel

# Same "find by pattern, rename to something fixed" treatment as
# fteqw-server/Dockerfile's SV_BIN - ftemaster's own filename varies with
# FTE_TARGET (engine/Makefile's EXEPOSTFIX/BITS suffixing).
RUN MASTER_BIN="$(find release -maxdepth 1 -type f -name 'ftemaster*' | head -n1)" \
    && test -n "$MASTER_BIN" \
    && cp "$MASTER_BIN" release/ftemaster-bin

FROM ubuntu:24.04

# No runtime apt-get install here - same call as fteqw-server/Dockerfile's
# own final stage (also a bare ubuntu:24.04 with nothing added beyond the
# copied binary): whatever shared libs the binary actually needs
# dynamically are already satisfied by ubuntu:24.04's own base packages.

COPY --from=builder /src/engine/release/ftemaster-bin /usr/local/bin/ftemaster
RUN chmod +x /usr/local/bin/ftemaster

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# sv_masterport_tcp - the broker's WebSocket-upgrade listen port, see
# fteqw's own specs/hosting.txt ("WebRTC / ICE") and net_ice.c. Point a
# reverse proxy's WebSocket support at this, same as fteqw-server's own
# SV_PORT_TCP - see the README.
EXPOSE 27950/tcp

ENTRYPOINT ["/docker-entrypoint.sh"]
