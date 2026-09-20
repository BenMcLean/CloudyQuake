# Build context is this directory (fteqw-server/) - unlike nginx/Dockerfile
# this needs no sibling files, since fteqw itself is fetched at build time
# (see FTEQW_REF) rather than vendored into the repo.
#
# fteqw is used here entirely stock, with no project-specific patches, so a
# pinned build-time clone is the right call rather than a vendored subtree -
# same treatment CloudyDoom gave its own unmodified dedicated server
# (chocolate-doom, cloned via CHOCOLATE_DOOM_REF), as opposed to doom-wasm
# (a project-specific fork, which *is* vendored there).

# GAME picks which game's gamecode gets baked into this image, and therefore
# which builder stage below actually runs - see docker-entrypoint.sh (which
# reads the same var at runtime to pick the matching engine-mode flag) and
# GAME in .env.example. "qw" (default) needs fteqw's own QuakeC gamecode
# (gamecode-qw below); "quake2" needs a natively-compiled Quake II gamecode
# library that fteqw itself doesn't provide or build (see gamecode-quake2
# below) - unlike Hexen II, which needs no build-time gamecode of its own at
# all (its progs.dat/portals mission pack ship in your own retail pak files -
# see BASE_GAMEDIR/SERVER_ARGS in .env.example), so it has no gamecode-*
# stage here and just keeps using GAME=qw's engine build.
ARG GAME=qw

# fteqw tags releases as dated snapshots (e.g. "2025-09-27") rather than
# semver - pinned here instead of "master" so a rebuild doesn't silently
# pick up unreviewed upstream changes. Check
# https://github.com/fte-team/fteqw/tags for newer ones.
ARG FTEQW_REF=2025-09-27

# --- engine-builder: the native dedicated server binary, same regardless of
# GAME - fteqw's sv-rel target links no gamecode of its own, whichever game
# actually gets played is entirely down to what gamecode ends up on disk at
# runtime (baked in below, or from your own pak volume for Hexen II).
FROM ubuntu:24.04 AS engine-builder
ARG FTEQW_REF

# Matches the linux build dependencies fteqw's own build_setup.sh documents
# for its "Build for Linux x86_64?" option, plus its generic prerequisites
# (git/automake/libtool/p7zip/zip/wget/pkg-config - "makelibs" below shells
# out to wget and pkg-config directly to fetch and configure bundled
# third-party library sources like libjpeg, neither of which build-essential
# pulls in on its own) and build-essential itself to actually drive the
# Makefile.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential automake libtool \
        p7zip-full zip wget pkg-config \
        gcc-multilib g++-multilib mesa-common-dev \
        libasound2-dev libxcursor-dev libgnutls28-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src

WORKDIR /src/engine
# sv-rel: the dedicated QuakeWorld/NetQuake/Quake II server (no video/audio
#   code linked in at all - see engine/Makefile's SV_OBJS, which excludes
#   every GL/client object file). Quake II support is compiled in
#   unconditionally by this target; whether it's actually usable at runtime
#   depends only on whether Quake II gamecode is present on disk (see
#   SVQ2_GetGameAPI's dlopen search - gamecode-quake2 below bakes one in at
#   one of the paths it checks) - nothing else here needs to change per
#   GAME.
# qcc-rel: fteqcc, the QuakeC compiler - used below (build time only, qw
#   only) to compile quakec/basemod into gamecode, so the image ships with a
#   working qwprogs.dat without depending on a separately-sourced file.
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

# Every gamecode-* stage below stages its output under /out/, laid out as an
# exact mirror of the final image's own filesystem (e.g.
# /out/fte/qw/qwprogs.dat, /out/usr/local/bin/libgame_baseq2.so) - so the
# final stage can copy whichever one GAME selected with a single
# `COPY --from=gamecode /out/ /`, unconditionally, regardless of which of
# these actually ran. Keeps the final stage itself free of any per-GAME
# branching, and makes adding a future GAME value (another engine mode
# needing its own baked gamecode) a matter of adding one more stage here,
# nothing else.

# --- gamecode-qw: fteqw's own id1-equivalent QuakeC reimplementation
# (quakec/basemod, see its own basemod.txt for license terms) - openly
# licensed, unlike the retail map/model/texture data in
# id1/pak0.pak+pak1.pak, which is never baked into this image and always
# comes from your own volume mount instead (see docker-compose.yml).
# progs.src's default #pragma PROGS_DAT (no NETQUAKE/FTE #define set) names
# the output qwprogs.dat. qw/ is fteqw's own always-loaded gamedir for this
# mode (see docker-entrypoint.sh's "-game qw"), so the output lands where
# that gamedir will actually be searched from.
FROM engine-builder AS gamecode-qw
WORKDIR /src/quakec/basemod
RUN QCC_BIN="$(find /src/engine/release -maxdepth 1 -type f -name 'fteqcc*' -executable | head -n1)" \
    && test -n "$QCC_BIN" \
    && "$QCC_BIN" progs.src
RUN mkdir -p /out/fte/qw \
    && cp qwprogs.dat /out/fte/qw/qwprogs.dat

# --- gamecode-quake2: unlike QuakeWorld/Hexen II (both plain QuakeC, run by
# fteqw's own VM), Quake II's gamecode is a natively-compiled shared library
# using id Tech 2's game DLL ABI, which fteqw dlopen()s at runtime
# (engine/server/svq2_game.c's SVQ2_GetGameAPI) rather than interpreting
# itself - fteqw ships none of its own ("FTE doesn't provide gamecode.
# Borrow someone else's." - svq2_game.c's own comment), so one has to be
# built from elsewhere. yquake2 (github.com/yquake2/yquake2, GPLv2, the
# same license as id Software's original Quake II source release) is used
# here purely for its src/game/ - the "baseq2/game.so" target below builds
# only that (GAME_OBJS in yquake2's Makefile: src/common/shared/ + src/game/
# - no SDL2/GL/OpenAL, none of yquake2's own client/server/renderer code),
# not yquake2's own client or server, which this project has no use for.
#
# SVQ2_GetGameAPI's dlopen search checks several locations; the one used
# here - "<binarydir>/libgame_<gamedir>.ext" - is the only one that's both
# unconditional (others require com_gamedirnativecode, off by default) and
# outside the gamedir itself, which matters because gamedirs (BASE_GAMEDIR,
# and each of GAMEDIRS below) are runtime symlinks straight into your own
# read-only PAK_DIR volume (see docker-entrypoint.sh's link_gamedir) -
# anything baked in *inside* one would just be hidden once that symlink goes
# up. <binarydir> is wherever fteqw-server-bin itself lives (/usr/local/bin,
# set below), so each library's own filename is what ties it to a specific
# gamedir name ("libgame_baseq2.so", "libgame_rogue.so", ...) - matching
# BASE_GAMEDIR/GAMEDIRS is on you, same as it always is for pak-volume
# folder names (see .env.example).
FROM ubuntu:24.04 AS gamecode-quake2

# yquake2 tags stable releases as QUAKE2_<major>_<minor> (not semver either) -
# pinned instead of "master" for the same reason as FTEQW_REF above. Check
# https://github.com/yquake2/yquake2/tags for newer ones.
ARG YQUAKE2_REF=QUAKE2_8_70

# The three official id Software expansions/mods, each maintained by the
# yquake2 org as its own from-scratch GPLv2 reimplementation of just that
# gamecode (github.com/yquake2/rogue|xatrix|ctf) - same "no client/renderer,
# just the game library" shape as yquake2/yquake2 itself, and each tags
# releases as <NAME>_<major>_<minor>. These are ADDITIONAL gamedirs
# (GAMEDIRS=rogue/xatrix/ctf on top of BASE_GAMEDIR=baseq2 - see
# .env.example), not alternatives to baseq2's own gamecode above, so all
# three get built unconditionally here rather than gated behind their own
# ARGs - each takes a few seconds and needs nothing beyond git/gcc/make, and
# whether they actually end up used at runtime is GAMEDIRS's call, not a
# build-time one.
ARG ROGUE_REF=ROGUE_2_16
ARG XATRIX_REF=XATRIX_2_17
ARG CTF_REF=CTF_1_13

# Action Quake 2 ("action") - a third-party multiplayer mod, not an id
# Software expansion, but still just gamecode source in the same standalone
# shape as the three above (github.com/aq2-tng/aq2-tng: real preserved CVS
# history from the mod's original 2003-2004 development, not a decompile -
# cited by name as "Action Quake Libraries" by AQtion, the actively
# maintained continuation of the mod at github.com/actionquake/distrib,
# which documents its own GPLv2 compliance with id's Quake II source terms).
# No tagged releases exist, so this one's pinned to an exact commit instead
# (see the fetch/checkout below - aq2-tng's Makefile has no plain "game"
# target either, just its default one, and names the output
# "game<arch>.so" rather than "game.so").
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

# rogue/xatrix/ctf's own Makefiles - unlike the main engine repo's, which
# needs "make game" specifically - build via their default "all" target
# (plain "make"), straight to release/game.so (no per-gamedir subfolder,
# since each repo only ever builds the one mod it's named for).
WORKDIR /src-rogue
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_rogue.so

WORKDIR /src-xatrix
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_xatrix.so

WORKDIR /src-ctf
RUN make \
    && cp release/game.so /out/usr/local/bin/libgame_ctf.so

# aq2-tng builds straight in its source/ dir (no BINDIR/release split the
# other repos use) and names its own output "game<arch>.so" - x86_64 here,
# matching FTE_TARGET=linux64 above.
WORKDIR /src-aq2tng/source
RUN make \
    && cp gamex86_64.so /out/usr/local/bin/libgame_action.so

# --- gamecode: picks whichever gamecode-* stage above matches GAME. Docker
# resolves this FROM at build time from the ARG, so only the matching
# stage's RUN steps (and its own dependency chain) actually execute - the
# other one is never built at all, keeping e.g. a plain GAME=qw build exactly
# as fast/small as before this file grew a second gamecode stage.
FROM gamecode-${GAME} AS gamecode

FROM ubuntu:24.04

COPY --from=engine-builder /src/engine/release/fteqw-server-bin /usr/local/bin/fteqw-server
RUN chmod +x /usr/local/bin/fteqw-server

# -basedir itself (see docker-entrypoint.sh's BASEDIR) has to exist before
# any gamedir can be symlinked into it - unconditional here since not every
# gamecode-* stage above happens to create it as a side effect of its own
# output (gamecode-qw's /out/fte/qw/ does; gamecode-quake2's
# /out/usr/local/bin/ doesn't).
RUN mkdir -p /fte

# See the gamecode-* stages above for what actually lands where - qw/'s own
# baked-in QuakeC gamecode for GAME=qw, or a baked-in libgame_baseq2.so
# (found by fteqw's own dlopen search, see gamecode-quake2 above) for
# GAME=quake2. Either way, id1/ (or baseq2/, or any other gamedir - GAMEDIRS,
# a full retail install, ...) is never baked in here - docker-entrypoint.sh
# symlinks it in from the PAK_DIR volume at container start (see its
# comment, and /fte-data in docker-compose.yml), overriding qw/ too if your
# own volume happens to provide one (e.g. from a full retail install).
COPY --from=gamecode /out/ /

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
