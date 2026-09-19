# Build context is this directory (fteqw-server/) - unlike nginx/Dockerfile
# this needs no sibling files, since fteqw itself is fetched at build time
# (see FTEQW_REF) rather than vendored into the repo.
#
# fteqw is used here entirely stock, with no project-specific patches, so a
# pinned build-time clone is the right call rather than a vendored subtree -
# same treatment CloudyDoom gave its own unmodified dedicated server
# (chocolate-doom, cloned via CHOCOLATE_DOOM_REF), as opposed to doom-wasm
# (a project-specific fork, which *is* vendored there).
FROM ubuntu:24.04 AS builder

# fteqw tags releases as dated snapshots (e.g. "2025-09-27") rather than
# semver - pinned here instead of "master" so a rebuild doesn't silently
# pick up unreviewed upstream changes. Check
# https://github.com/fte-team/fteqw/tags for newer ones.
ARG FTEQW_REF=2025-09-27

# Matches the linux build dependencies fteqw's own build_setup.sh documents
# for its "Build for Linux x86_64?" option, plus git/build-essential to
# actually clone and drive the Makefile.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential \
        gcc-multilib g++-multilib mesa-common-dev \
        libasound2-dev libxcursor-dev libgnutls28-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src

WORKDIR /src/engine
# sv-rel: the dedicated QuakeWorld/NetQuake server (no video/audio code
#   linked in at all - see engine/Makefile's SV_OBJS, which excludes every
#   GL/client object file).
# qcc-rel: fteqcc, the QuakeC compiler - used below (build time only) to
#   compile quakec/basemod into gamecode, so the image ships with a working
#   qwprogs.dat without depending on a separately-sourced file.
RUN make FTE_TARGET=linux64 makelibs \
    && make -j"$(nproc)" FTE_TARGET=linux64 sv-rel qcc-rel

# The dedicated server binary's exact filename varies with fteqw's own
# naming convention (engine/Makefile has a different SV_EXE_NAME= for nearly
# every FTE_TARGET) - found by pattern and renamed to something fixed, so
# this Dockerfile doesn't silently break if upstream renames it between
# releases.
RUN SV_BIN="$(find release -maxdepth 1 -type f -name '*-sv*' | head -n1)" \
    && test -n "$SV_BIN" \
    && cp "$SV_BIN" release/fteqw-server-bin

# Compile the standard QuakeWorld gamecode. quakec/basemod is fteqw's own
# id1-equivalent QuakeC reimplementation (see its own basemod.txt for
# license terms) - openly licensed, unlike the retail map/model/texture
# data in id1/pak0.pak+pak1.pak, which is never baked into this image and
# always comes from your own volume mount instead (see docker-compose.yml).
# progs.src's default #pragma PROGS_DAT (no NETQUAKE/FTE #define set) names
# the output qwprogs.dat.
WORKDIR /src/quakec/basemod
RUN QCC_BIN="$(find /src/engine/release -maxdepth 1 -type f -name 'fteqcc*' -executable | head -n1)" \
    && test -n "$QCC_BIN" \
    && "$QCC_BIN" progs.src

FROM ubuntu:24.04

COPY --from=builder /src/engine/release/fteqw-server-bin /usr/local/bin/fteqw-server
RUN chmod +x /usr/local/bin/fteqw-server

# Standard QuakeWorld directory layout: id1/ holds the shared NetQuake
# assets (pak0.pak/pak1.pak - your own retail copy, mounted read-only as a
# volume at container start, see PAK_DIR in docker-compose.yml - never
# baked into this image), qw/ holds QuakeWorld-specific gamecode.
# qwprogs.dat is baked in at build time since it's built from fteqw's own
# openly-licensed quakec/basemod source above, not copyrighted retail
# content.
RUN mkdir -p /fte/id1 /fte/qw
COPY --from=builder /src/quakec/basemod/qwprogs.dat /fte/qw/qwprogs.dat

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# sv_port (QuakeWorld's traditional default) - native UDP clients, connect
# straight to this, bypassing every proxy in front of the web tier.
EXPOSE 27500/udp
# sv_port_tcp - WebSocket clients (browser players via a reverse proxy) and
# native tcp/qizmo clients, same port/cvar - see fteqw's own
# specs/hosting.txt and specs/browser.txt.
EXPOSE 27500/tcp

ENTRYPOINT ["/docker-entrypoint.sh"]
