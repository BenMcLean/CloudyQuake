#!/bin/sh
set -eu

# -basedir /fte: qw/ (baked-in qwprogs.dat, see Dockerfile) lives here
# already; every other gamedir gets symlinked in below from the PAK_DIR
# volume (mounted at /fte-data, see docker-compose.yml) before the engine
# starts, since /fte itself is part of the image and can't just be
# replaced by a bind mount without losing the baked-in qw/.
BASEDIR=/fte
DATA_DIR=/fte-data

# Quake installs are conventionally cased however their original platform
# felt like (GOG/Steam Windows installs ship "Id1", not "id1", for
# instance), but fteqw's own default basegame lookup - and, critically, the
# browser client's sandboxed virtual filesystem, which has no OS-level
# case-insensitive fallback to lean on the way native builds do - expect
# the lowercase "id1"/"pak0.pak" convention exactly. So gamedirs here are
# matched against PAK_DIR case-*insensitively*, but always symlinked in
# under their canonical lowercase name, regardless of the real folder's
# actual casing - keeping the server side consistent with whatever
# nginx/auth.js resolves for the web client (see its own matching
# comment).
#
# link_gamedir CANONICAL: finds a case-insensitive match for CANONICAL
# among $DATA_DIR's top-level subfolders and symlinks it in as
# $BASEDIR/CANONICAL (lowercase). Returns failure if no match was found.
link_gamedir() {
    canon="$1"
    [ -d "$DATA_DIR" ] || return 1
    for d in "$DATA_DIR"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        lc_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        if [ "$lc_name" = "$canon" ]; then
            target="$BASEDIR/$canon"
            # A pre-existing real directory at the same name (i.e. only
            # qw/, baked into the image) is removed first so your own
            # copy - if PAK_DIR happens to provide one, e.g. from a full
            # retail install - takes priority over the built-in one
            # instead of ln silently nesting inside it.
            if [ -e "$target" ] && [ ! -L "$target" ]; then
                rm -rf "$target"
            fi
            ln -sfn "$d" "$target"
            return 0
        fi
    done
    return 1
}

# BASE_GAMEDIR is purely our own pak-volume convention, not an fteqw flag:
# it's whichever PAK_DIR subfolder gets symlinked in as fteqw's implicit
# default gamedir (the one always loaded with no "-game" needed) - "id1"
# for stock Quake/QuakeWorld, or "data1" if you're pointing SERVER_ARGS at
# a different game (e.g. Hexen II) whose own retail layout calls its base
# folder something else. This has no bearing on which fteqw flags actually
# get passed to the engine - that's entirely SERVER_ARGS's job, below.
BASE_GAMEDIR="${BASE_GAMEDIR:-id1}"

if ! link_gamedir "$BASE_GAMEDIR"; then
    echo "WARNING: no $BASE_GAMEDIR/ (any case) folder found under PAK_DIR - the server has no base game data and will fail to load a map. See the README's 'Getting paks' section." >&2
fi

SV_PORT="${SV_PORT:-27500}"
# Same port number as SV_PORT by default is fine - UDP 27500 and TCP 27500
# are independent sockets. This is the port a reverse proxy/nginx-proxy-
# manager should point its ws(s):// upstream at - see specs/hosting.txt and
# specs/browser.txt in fteqw's own repo ("sv_port_tcp ... listens for tcp
# connections, including websocket clients").
SV_PORT_TCP="${SV_PORT_TCP:-27500}"

# The shared join password - independent of, but typically set to the same
# value as, the HTTP Basic Auth PASSWORD gating the web client/paks (see
# nginx/auth.js). This is what actually gates *joining the match*: HTTP
# Basic Auth can't reach a WebSocket handshake at all (browsers don't let
# JS attach an Authorization header to one), so the web client instead
# stuffs "+password" as a startup arg once it already knows this value from
# /config.json - see nginx/config.base.json.template and
# nginx/site/app.js. Native UDP clients set it the same way any QuakeWorld
# server password always has: "password" in their config, or "connect
# host:port" then typing it if prompted. Empty/unset means no password
# required to join.
PASSWORD="${PASSWORD:-}"

# GAME picks which game this server actually runs, and therefore which
# engine-mode flag gets forced on here - not something SERVER_ARGS can drop.
# Also read at build time (see Dockerfile's ARG GAME) to decide which
# gamecode gets baked into this image, so it has to agree with whatever this
# image was actually built with (an image built GAME=qw has no Quake II
# gamecode on disk to dlopen, and vice versa - see .env.example).
#
# "qw" (default): QuakeWorld - "-game qw" is fteqw's own always-loaded
#   gamedir for it (QuakeWorld was never part of any retail Quake release,
#   so there's no equivalent implicit default the way id1/baseq2 are for
#   NetQuake/Quake II). This is also what Hexen II runs under: it needs no
#   gamecode of its own baked in (its progs.dat/portals mission pack come
#   entirely from your own retail pak files - see BASE_GAMEDIR above), just
#   SERVER_ARGS=-hexen2 layered on top of this same "-game qw" - matches
#   fteqw's own description of Hexen II as "just... a glorified mod" of the
#   same QuakeC VM/protocol.
# "quake2": Quake II - "-quake2" switches the engine's protocol/gamecode
#   loading to id Tech 2 mode, whose own retail layout already treats
#   baseq2/ as its implicit default gamedir (no explicit "-game" needed, same
#   as Hexen II's data1/). See the README's Quake II section.
GAME="${GAME:-qw}"
case "$GAME" in
    qw)
        set -- -game qw
        ;;
    quake2)
        set -- -quake2
        ;;
    *)
        echo "WARNING: unknown GAME '$GAME' - falling back to qw" >&2
        set -- -game qw
        ;;
esac

# GAMEDIRS then optionally stacks any number of further gamedirs on top -
# space-separated, applied in order, e.g. "hipnotic mymappack" for a
# mission pack plus a custom map pack on top of stock Quake, or "portals"
# for Hexen II's own Portal of Praevus mission pack. fteqw's own -game
# handling supports repeating the flag to build a search-path stack of up
# to 8 total gamedirs (later ones taking priority for same-named files) -
# see fteqw's engine/common/fs.c/common.h (MAX_GAMES-equivalent:
# gamepath[8]).
#
# A standalone map or small map pack often doesn't need its own gamedir at
# all: fteqw will auto-download any map a client doesn't already have
# straight from this server over the game connection (see fteqw's
# specs/browser.txt - "custom maps do not need to be named in manifests as
# they will just be downloaded from the game server automatically"), so
# just dropping extra .bsp files into an existing gamedir's maps/ folder
# also works, with no config here and no pak/nginx involvement at all -
# GAMEDIRS is for when you specifically want a map pack's own gamedir
# (e.g. it ships alongside its own textures/sounds as a pak).
for gd in ${GAMEDIRS:-}; do
    gd=$(printf '%s' "$gd" | tr '[:upper:]' '[:lower:]')
    if ! link_gamedir "$gd"; then
        echo "WARNING: GAMEDIRS entry '$gd' has no matching folder (any case) under PAK_DIR - skipping it." >&2
        continue
    fi
    set -- "$@" -game "$gd"
done

# SERVER_ARGS is a raw, space-separated passthrough of whatever remaining
# startup switches/cvars fteqw itself actually takes, reaching only
# fteqw-server - see CLIENT_ARGS (nginx/docker-entrypoint.sh) for the
# client-side equivalent. Hostname, starting map, deathmatch, maxclients,
# sv_public, and every other ordinary fteqw session setting deliberately
# have no named var of their own here and no default beyond fteqw's own -
# it's not this container's job to babysit settings that don't affect
# whether the container itself works, and every one added here is one
# more thing that can drift from whatever fteqw calls it/defaults it to
# in some future version. Set them the same way you would running fteqw
# directly, e.g. SERVER_ARGS="+set hostname MyServer +set deathmatch 1
# -dedicated 16 +set sv_public 0 +map dm3" - see .env.example for a fuller
# example and fteqw's own specs/hosting.txt and in-engine "help" command
# for what's available. Also where a different fteqw game/mode goes - e.g.
# SERVER_ARGS="-hexen2" together with BASE_GAMEDIR=data1 for Hexen II,
# whose own retail data already ships its own gamecode (see
# .env.example), so nothing extra needs to be baked in for that case.
SERVER_ARGS="${SERVER_ARGS:-}"

# Opt-in WebRTC path via a self-hosted broker (the ftemaster service) -
# see the README's WebRTC section and fteqw's own specs/hosting.txt
# ("WebRTC / ICE"). The cvar is "sv_port_rtc" (RTC, not RTP - the doc
# comment above and specs/hosting.txt itself both say "sv_port_rtp", which
# doesn't exist anywhere in fteqw's own source; confirmed by reading
# engine/common/net_wins.c's SV_PortRTC_Callback/sv_port_rtc directly).
# Both blank by default, meaning no change from today's UDP/WSS-only
# behavior - only appended when actually set, same reasoning as
# SV_PORT/SV_PORT_TCP/PASSWORD below not forcing an empty "+set" either.
#
# SV_PORT_RTC: this server's broker-registered name (e.g. "/myserver") -
#   clients then "connect /myserver" over ICE/holepunching instead of a
#   direct UDP/WS(S) address.
# NET_ICE_BROKER: which broker to register with (fteqw's own
#   "net_ice_broker" cvar) - point this at your own ftemaster service
#   (through a reverse proxy - see the README) rather than fteqw's own
#   frag-net.com default.
SV_PORT_RTC="${SV_PORT_RTC:-}"
NET_ICE_BROKER="${NET_ICE_BROKER:-}"
if [ -n "$SV_PORT_RTC" ]; then
    set -- "$@" +set sv_port_rtc "$SV_PORT_RTC"
fi
if [ -n "$NET_ICE_BROKER" ]; then
    set -- "$@" +set net_ice_broker "$NET_ICE_BROKER"
fi

# chocolate-doom's stdout-buffering bug (see CloudyDoom's doom-server
# entrypoint) applies just as much here: under Docker, stdout is never a
# TTY, so C's stdio switches to fully-buffered and fteqw's own logging would
# otherwise sit in a buffer and never reach `docker logs`.
# The forced -game/+set flags run before SERVER_ARGS so that anything you
# put there - including its own +map or +set commands - executes
# afterward and isn't silently pre-empted by these container-required
# ones ("+" commands run in the order given, unlike "-" switches - see
# .env.example's CLIENT_ARGS comment).
set -f
set -- "$@" +set sv_port "$SV_PORT" +set sv_port_tcp "$SV_PORT_TCP" +set password "$PASSWORD" $SERVER_ARGS
set +f
exec stdbuf -oL -eL /usr/local/bin/fteqw-server \
    -basedir "$BASEDIR" \
    "$@"
