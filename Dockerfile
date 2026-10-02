# CloudyQuake as a single linuxserver.io-style image: fteqw's dedicated
# server, its WebRTC broker (ftemaster) and the nginx-served browser client
# all run in one container, supervised by s6-overlay. Build context is the
# repo root:
#   docker build -t cloudyquake .
#
# fteqw is used entirely stock, with no project-specific patches, so it's
# fetched at build time (see FTEQW_REF) rather than vendored.

# One image serves every game: the gamecode for all of them is baked in, and
# the container's GAME env var (see svc-fteqw-server/run and .env.example)
# picks which one actually runs. Published for linux/amd64 and linux/arm64.

# fteqw tags releases as dated snapshots rather than semver - pinned instead
# of "master" so a rebuild doesn't silently pick up unreviewed upstream
# changes. Check https://github.com/fte-team/fteqw/tags for newer ones.
ARG FTEQW_REF=2025-09-27

# --- wasm-builder: the browser client (ftewebgl.{js,wasm}) from fteqw's
# web/Emscripten port. emsdk version matches what fteqw's own CI verifies
# (.github/workflows/main.yml's "web" matrix entry) - don't bump one without
# checking the other still builds.
# The wasm output is architecture-independent, and emsdk only publishes
# amd64, so this runs on amd64 only. CI builds it once on an amd64 runner
# (`--target wasm`) and hands the result to every platform's image build as
# a named context (`--build-context wasm=<dir>`), which replaces the `wasm`
# stage below so this builder never runs on arm64.
FROM --platform=linux/amd64 emscripten/emsdk:2.0.12 AS wasm-builder
ARG FTEQW_REF
RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src
WORKDIR /src/engine
# The "web" target uses browser-native loaders for audio/image decoding, so
# nothing extra is needed beyond what the emsdk image has.
RUN make FTE_TARGET=web makelibs \
    && make -j"$(nproc)" FTE_TARGET=web gl-rel

# The browser client, as a bare filesystem: both the final image's source for
# these files and the `--target wasm` export CI uses.
FROM scratch AS wasm
COPY --from=wasm-builder /src/engine/release/ftewebgl.js /src/engine/release/ftewebgl.wasm /

# --- fte-src: fteqw source with its bundled libs built, shared by the
# native builder stages below so makelibs only runs once.
FROM ubuntu:24.04 AS fte-src
ARG FTEQW_REF
ARG TARGETARCH
# fteqw's "linux64" target hard-codes "gcc -m64", which doesn't exist on
# aarch64; its "linux_arm64" target wants aarch64-linux-gnu-* compilers
# instead (the cross packages work natively on an arm64 host). gcc-multilib
# only exists on amd64.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential automake libtool \
        p7zip-full zip wget pkg-config \
        mesa-common-dev libasound2-dev libxcursor-dev libgnutls28-dev zlib1g-dev \
    && if [ "$TARGETARCH" = arm64 ]; then \
        apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu g++-aarch64-linux-gnu; \
        echo linux_arm64 > /fte_target; \
    else \
        apt-get install -y --no-install-recommends gcc-multilib g++-multilib; \
        echo linux64 > /fte_target; \
    fi \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src
WORKDIR /src/engine
# engine/Makefile fetches libpng from prdownloads.sourceforge.net, which is
# often down or hanging (HTTP 522). The Makefile skips its own wget when the
# tarball already exists, so pre-seed it from GitHub's tag archive. Keep the
# version in sync with PNGVER in engine/Makefile if FTEQW_REF changes.
RUN wget --tries=5 --retry-connrefused --waitretry=3 -O libpng-1.6.45.tar.gz \
        https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.45.tar.gz \
    && make FTE_TARGET=$(cat /fte_target) makelibs

# --- sv-builder: the dedicated server (sv-rel, no client/GL objects) plus
# fteqcc (qcc-rel), used below to compile quakec/basemod. Binary filenames
# vary with FTE_TARGET, so they're found by pattern and renamed.
FROM fte-src AS sv-builder
RUN make -j"$(nproc)" FTE_TARGET=$(cat /fte_target) sv-rel qcc-rel
RUN SV_BIN="$(find release -maxdepth 1 -type f -name '*-sv*' | head -n1)" \
    && test -n "$SV_BIN" \
    && cp "$SV_BIN" release/fteqw-server-bin

# --- master-builder: ftemaster, the WebRTC/ICE broker and legacy master
# server (engine/Makefile's "master-rel", -DMASTERONLY). Built from its own
# stage so its objects can't mix with sv-rel's.
FROM fte-src AS master-builder
RUN make -j"$(nproc)" FTE_TARGET=$(cat /fte_target) master-rel
RUN MASTER_BIN="$(find release -maxdepth 1 -type f -name 'ftemaster*' | head -n1)" \
    && test -n "$MASTER_BIN" \
    && cp "$MASTER_BIN" release/ftemaster-bin

# Every gamecode-* stage stages its output under /out/, laid out as an
# exact mirror of the final image's filesystem, so the final stage can copy
# each one with a plain `COPY --from=... /out/ /`.

# --- gamecode-qw: fteqw's own id1-equivalent QuakeC reimplementation
# (quakec/basemod) - openly licensed, unlike the retail data in
# id1/pak0.pak+pak1.pak, which is never baked in and always comes from your
# /paks volume. qw/ is fteqw's own always-loaded gamedir for this mode.
FROM sv-builder AS gamecode-qw
WORKDIR /src/quakec/basemod
RUN QCC_BIN="$(find /src/engine/release -maxdepth 1 -type f -name 'fteqcc*' -executable | head -n1)" \
    && test -n "$QCC_BIN" \
    && "$QCC_BIN" progs.src
RUN mkdir -p /out/fte/qw \
    && cp qwprogs.dat /out/fte/qw/qwprogs.dat

# --- gamecode-quake2: Quake II's gamecode is a natively-compiled shared
# library fteqw dlopen()s (SVQ2_GetGameAPI) and ships none of its own. The
# yquake2 org's from-scratch GPLv2 reimplementations are built here, game
# library only (no client/renderer). Installed as
# <binarydir>/libgame_<gamedir>.so, the one dlopen location that's
# unconditional and outside the gamedir itself (gamedirs are runtime
# symlinks into /paks, which would hide anything baked in inside one).
# Matching BASE_GAMEDIR/GAMEDIRS to those names is on you - see .env.example.
FROM ubuntu:24.04 AS gamecode-quake2
ARG YQUAKE2_REF=QUAKE2_8_70
# The official expansions are separate repos, each tagged <NAME>_<major>_<minor>.
ARG ROGUE_REF=ROGUE_2_16
ARG XATRIX_REF=XATRIX_2_17
ARG CTF_REF=CTF_1_13
# Action Quake 2 is a third-party mod with no tagged releases (aq2-tng's
# preserved history of the original mod), so it's pinned to a commit.
ARG AQ2TNG_REF=472459e5ebf7955588d57c9d89216b1c134d5fa5

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$YQUAKE2_REF" https://github.com/yquake2/yquake2.git /src-yq2
RUN git clone --depth 1 --branch "$ROGUE_REF" https://github.com/yquake2/rogue.git /src-rogue
RUN git clone --depth 1 --branch "$XATRIX_REF" https://github.com/yquake2/xatrix.git /src-xatrix
RUN git clone --depth 1 --branch "$CTF_REF" https://github.com/yquake2/ctf.git /src-ctf
RUN mkdir /src-aq2tng && cd /src-aq2tng \
    && git init -q \
    && git remote add origin https://github.com/aq2-tng/aq2-tng.git \
    && git fetch --depth 1 origin "$AQ2TNG_REF" \
    && git checkout -q FETCH_HEAD

RUN mkdir -p /out/usr/local/bin

WORKDIR /src-yq2
RUN make game \
    && cp release/baseq2/game.so /out/usr/local/bin/libgame_baseq2.so

WORKDIR /src-rogue
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_rogue.so

WORKDIR /src-xatrix
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_xatrix.so

WORKDIR /src-ctf
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_ctf.so

# aq2-tng builds in its source/ dir and names its output game<arch>.so.
WORKDIR /src-aq2tng/source
RUN make \
    && cp "$(ls game*.so | head -n1)" /out/usr/local/bin/libgame_action.so

# --- Final image
FROM ghcr.io/linuxserver/baseimage-ubuntu:noble

LABEL maintainer="BenMcLean"
LABEL org.opencontainers.image.title="CloudyQuake"
LABEL org.opencontainers.image.source="https://github.com/BenMcLean/cloudyquake"

# nginx from nginx.org rather than Ubuntu's own package, because only
# nginx.org ships nginx-module-njs (used by nginx/auth.js).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg ca-certificates gettext-base \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu noble nginx" \
        > /etc/apt/sources.list.d/nginx.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        nginx nginx-module-njs \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /etc/nginx/conf.d /tmp/*

COPY --from=sv-builder /src/engine/release/fteqw-server-bin /usr/local/bin/fteqw-server
COPY --from=master-builder /src/engine/release/ftemaster-bin /usr/local/bin/ftemaster
COPY --from=wasm /ftewebgl.js /ftewebgl.wasm /usr/share/nginx/html/

# -basedir for fteqw-server. qw/ (baked-in gamecode, or libgame_*.so for
# GAME=quake2) come from the gamecode stages; every other gamedir gets
# symlinked in from /paks at container start by init-cloudyquake-config.
RUN mkdir -p /fte /paks
COPY --from=gamecode-qw /out/ /
COPY --from=gamecode-quake2 /out/ /

# s6 service definitions, nginx.conf, auth.js, the site and config template.
COPY root/ /

RUN chmod +x /usr/local/bin/fteqw-server /usr/local/bin/ftemaster \
    && find /etc/s6-overlay/s6-rc.d -type f -name run -exec chmod +x {} +

# Make a failed init (e.g. neither NET_ICE_BROKER nor WS_URL set) stop the
# container instead of leaving it half-running.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# 8080: web client. 27500: fteqw-server (udp = native/WebRTC, tcp =
# WebSocket). 27950: ftemaster (tcp = signaling, udp = STUN).
EXPOSE 8080 27500/udp 27500/tcp 27950/tcp 27950/udp

# /config: fteqw's own config/logs. /paks: your retail game data (read-only
# is fine - nothing writes there).
VOLUME /config
