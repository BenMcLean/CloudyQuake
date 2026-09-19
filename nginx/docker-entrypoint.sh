#!/bin/sh
set -eu

: "${CLOUDYQUAKE_WS_URL:?CLOUDYQUAKE_WS_URL must be set, e.g. wss://quakeworld.example.com}"

# PASSWORD is intentionally optional and not read anywhere in this script -
# nginx/auth.js reads it straight from the environment at request time (via
# nginx.conf's "env PASSWORD;"), and embeds it in /config.json itself so it
# never needs duplicating into config.base.json here.

# Which pak files actually get served/preloaded (id1/*.pak, plus each of
# GAMEDIRS's own *.pak if set) is discovered fresh per-request by
# nginx/auth.js's config() - not resolved here, since it depends on what's
# actually present in the /paks volume mount, which can change without a
# container restart.

# JSON-escapes a string onto stdout (backslash and double-quote only - the
# inputs here are all plain ASCII command line flags/filenames, never
# arbitrary user text, so no other escaping is needed).
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# EXTRA_ARGS is a whitespace-separated string of raw fteqw command line
# flags/cvars for anything site/app.js doesn't already set explicitly (e.g.
# "+set rate 25000 +set cl_nolerp 1"). Unlike Doom's netcode, QuakeWorld is
# client-server authoritative - the server simulates the game and the
# client just renders/predicts, so (unlike CloudyDoom's DOOM_EXTRA_ARGS)
# there's no requirement that every client's settings match the server's or
# each other's. Unset by default - fteqw's own client defaults apply.
EXTRA_ARGS_JSON="["
first=1
set -f
for arg in ${EXTRA_ARGS:-}; do
    if [ "$first" -eq 1 ]; then
        first=0
    else
        EXTRA_ARGS_JSON="${EXTRA_ARGS_JSON},"
    fi
    EXTRA_ARGS_JSON="${EXTRA_ARGS_JSON}\"$(json_escape "$arg")\""
done
set +f
export CLOUDYQUAKE_EXTRA_ARGS_JSON="${EXTRA_ARGS_JSON}]"

# nativeClientCmd is a convenience field for humans only - site/app.js never
# reads it. It's the equivalent command line a player running their own
# native fteqw client (not the browser) would need to join this exact
# server, connecting straight to fteqw-server's UDP port and bypassing
# nginx entirely - see the README's "Connecting" section. The host is
# derived from CLOUDYQUAKE_WS_URL on the assumption its hostname also
# resolves to fteqw-server's UDP port, which holds for the two-hostname
# split-domain setup the README recommends, but not for every possible
# deployment - it's a starting point to edit, not gospel.
CLOUDYQUAKE_WS_HOST=$(printf '%s' "$CLOUDYQUAKE_WS_URL" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/].*##')
# Unlike fteqw-server's own "-game qw" (server-side gamecode - see its
# docker-entrypoint.sh), a native *client* never executes gamecode, so it
# only needs "-game" for each of GAMEDIRS when a mission pack/mod/map pack
# changes client-visible assets (models/maps) to match what the server's
# running - not "qw" itself.
CLOUDYQUAKE_GAME_ARGS=""
for gd in ${GAMEDIRS:-}; do
    CLOUDYQUAKE_GAME_ARGS="${CLOUDYQUAKE_GAME_ARGS}-game ${gd} "
done
CLOUDYQUAKE_NATIVE_CMD="fteqw ${CLOUDYQUAKE_GAME_ARGS}+set password \"<your password>\" +connect ${CLOUDYQUAKE_WS_HOST}:${SV_PORT:-27500}"
export CLOUDYQUAKE_NATIVE_CMD_JSON=$(json_escape "$CLOUDYQUAKE_NATIVE_CMD")

# config.base.json holds everything in config.json except "playerName",
# "password", "gameFiles" and "gamedirs", which nginx/auth.js fills in
# per-request from the client's own Basic Auth credentials, the PASSWORD
# env var, and the /paks volume's actual contents respectively - see
# nginx.conf's "location = /config.json".
envsubst '${CLOUDYQUAKE_WS_URL} ${CLOUDYQUAKE_EXTRA_ARGS_JSON} ${CLOUDYQUAKE_NATIVE_CMD_JSON}' \
    < /etc/cloudyquake/config.base.json.template > /etc/cloudyquake/config.base.json

exec nginx -g 'daemon off;'
