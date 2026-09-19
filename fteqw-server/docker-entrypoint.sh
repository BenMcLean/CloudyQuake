#!/bin/sh
set -eu

# -basedir /fte: id1/ (mounted volume, your retail pak0.pak/pak1.pak) and
# qw/ (baked-in qwprogs.dat, see Dockerfile) both live under here.
# -game qw: QuakeWorld gamecode/mode, per fteqw's own directory convention.
BASEDIR=/fte

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

# chocolate-doom's stdout-buffering bug (see CloudyDoom's doom-server
# entrypoint) applies just as much here: under Docker, stdout is never a
# TTY, so C's stdio switches to fully-buffered and fteqw's own logging would
# otherwise sit in a buffer and never reach `docker logs`.
exec stdbuf -oL -eL /usr/local/bin/fteqw-server \
    -basedir "$BASEDIR" \
    -game qw \
    -dedicated "$MAXCLIENTS" \
    +set sv_port "$SV_PORT" \
    +set sv_port_tcp "$SV_PORT_TCP" \
    +set hostname "$SERVER_HOSTNAME" \
    +set deathmatch "$DEATHMATCH" \
    +set sv_public "$SV_PUBLIC" \
    +set password "$PASSWORD" \
    +map "$MAP"
