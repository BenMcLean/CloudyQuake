#!/bin/sh
set -eu

# -basedir /fte: qw/ (baked-in qwprogs.dat, see Dockerfile) lives here
# already; every other gamedir gets symlinked in below from the PAK_DIR
# volume (mounted at /fte-data, see docker-compose.yml) before the engine
# starts, since /fte itself is part of the image and can't just be
# replaced by a bind mount without losing the baked-in qw/.
BASEDIR=/fte
DATA_DIR=/fte-data

# Merge every gamedir subfolder found in the mounted volume (id1/,
# hipnotic/, rogue/, a mod's own folder, ...) into $BASEDIR as a symlink.
# A pre-existing real directory at the same name (i.e. only qw/, baked into
# the image) is removed first so your own copy - if PAK_DIR happens to
# provide one, e.g. from a full retail install - takes priority over the
# built-in one instead of ln silently nesting inside it.
if [ -d "$DATA_DIR" ]; then
    for d in "$DATA_DIR"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        target="$BASEDIR/$name"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
            rm -rf "$target"
        fi
        ln -sfn "$d" "$target"
    done
fi

SV_PORT="${SV_PORT:-27500}"
# Same port number as SV_PORT by default is fine - UDP 27500 and TCP 27500
# are independent sockets. This is the port a reverse proxy/nginx-proxy-
# manager should point its ws(s):// upstream at - see specs/hosting.txt and
# specs/browser.txt in fteqw's own repo ("sv_port_tcp ... listens for tcp
# connections, including websocket clients").
SV_PORT_TCP="${SV_PORT_TCP:-27500}"

MAP="${MAP:-dm3}"
DEATHMATCH="${DEATHMATCH:-1}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-CloudyQuake}"
MAXCLIENTS="${MAXCLIENTS:-16}"

# sv_public 0: don't send heartbeats to the public QW master servers or
# respond to their queries - this is a private, invite-only game (per the
# project's intent, unlike a normal public QuakeWorld server), reachable
# only by people you've given the URL+password to. LAN-local discovery
# still works fine either way; see specs/hosting.txt's sv_public docs.
SV_PUBLIC="${SV_PUBLIC:-0}"

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

# -game qw is always loaded first, for the baked-in/overridden QuakeWorld
# gamecode (see the symlink-merge above). GAMEDIR optionally stacks a
# mission pack or mod's own gamedir on top (fteqw's own -game handling
# supports repeating the flag to build a search-path stack, later ones
# taking priority - see fteqw's engine/common/fs.c). Leave GAMEDIR unset
# for base id1 + qw only.
GAMEDIR="${GAMEDIR:-}"
set -- -game qw
if [ -n "$GAMEDIR" ]; then
    set -- "$@" -game "$GAMEDIR"
fi

# chocolate-doom's stdout-buffering bug (see CloudyDoom's doom-server
# entrypoint) applies just as much here: under Docker, stdout is never a
# TTY, so C's stdio switches to fully-buffered and fteqw's own logging would
# otherwise sit in a buffer and never reach `docker logs`.
exec stdbuf -oL -eL /usr/local/bin/fteqw-server \
    -basedir "$BASEDIR" \
    "$@" \
    -dedicated "$MAXCLIENTS" \
    +set sv_port "$SV_PORT" \
    +set sv_port_tcp "$SV_PORT_TCP" \
    +set hostname "$SERVER_HOSTNAME" \
    +set deathmatch "$DEATHMATCH" \
    +set sv_public "$SV_PUBLIC" \
    +set password "$PASSWORD" \
    +map "$MAP"
