#!/bin/sh
set -eu

: "${WS_URL:?WS_URL must be set, e.g. wss://quakeworld.example.com}"

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

# CLIENT_ARGS is a whitespace-separated string of raw fteqw command line
# flags/cvars for anything site/app.js doesn't already set explicitly (e.g.
# "+set rate 25000 +set cl_nolerp 1") - the client-side counterpart to
# fteqw-server's own SERVER_ARGS (see its docker-entrypoint.sh), named
# distinctly so it's unambiguous which side of the connection each one
# actually reaches. Unlike Doom's netcode, QuakeWorld is client-server
# authoritative - the server simulates the game and the client just
# renders/predicts, so (unlike CloudyDoom's DOOM_EXTRA_ARGS) there's no
# requirement that every client's settings match the server's or each
# other's. Unset by default - fteqw's own client defaults apply.
CLIENT_ARGS_JSON="["
first=1
set -f
for arg in ${CLIENT_ARGS:-}; do
    if [ "$first" -eq 1 ]; then
        first=0
    else
        CLIENT_ARGS_JSON="${CLIENT_ARGS_JSON},"
    fi
    CLIENT_ARGS_JSON="${CLIENT_ARGS_JSON}\"$(json_escape "$arg")\""
done
set +f
export CLIENT_ARGS_JSON="${CLIENT_ARGS_JSON}]"

# nativeClientCmd is a convenience field for humans only - site/app.js never
# reads it. It's the equivalent command line a player running their own
# native fteqw client (not the browser) would need to join this exact
# server, connecting straight to fteqw-server's UDP port and bypassing
# nginx entirely - see the README's "Connecting" section. The host is
# derived from WS_URL on the assumption its hostname also
# resolves to fteqw-server's UDP port, which holds for the two-hostname
# split-domain setup the README recommends, but not for every possible
# deployment - it's a starting point to edit, not gospel.
WS_HOST=$(printf '%s' "$WS_URL" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[:/].*##')
# Unlike fteqw-server's own SERVER_ARGS (server-side, potentially including
# gamecode-mode switches like "-hexen2" - see its docker-entrypoint.sh), a
# native *client* never executes gamecode, so this only needs "-game" for
# each of GAMEDIRS when a mission pack/mod/map pack changes client-visible
# assets (models/maps) to match what the server's running. If SERVER_ARGS
# includes an engine-mode switch like "-hexen2", add it here manually too
# (or to your own native client's config) - this is a convenience starting
# point, not gospel, same as the rest of this field - see the README's
# "Connecting" section.
GAME_ARGS=""
for gd in ${GAMEDIRS:-}; do
    gd=$(printf '%s' "$gd" | tr '[:upper:]' '[:lower:]')
    GAME_ARGS="${GAME_ARGS}-game ${gd} "
done
# The real PASSWORD, not a placeholder: this whole field only reaches
# someone who already authenticated with that exact password (config.json
# is behind the same Basic Auth gate as everything else - see
# nginx/auth.js), so there's nothing left to protect by hiding it here,
# and a placeholder just means extra manual editing for every player
# copy-pasting this to set up a native client. Omitted entirely (rather
# than "+set password \"\"") when PASSWORD is blank, matching
# site/app.js's own conditional +password logic for the browser client.
PASSWORD_ARG=""
if [ -n "${PASSWORD:-}" ]; then
    PASSWORD_ARG="+set password \"${PASSWORD}\" "
fi
NATIVE_CMD="fteqw ${GAME_ARGS}${PASSWORD_ARG}+connect ${WS_HOST}:${SV_PORT:-27500}"
export NATIVE_CMD_JSON=$(json_escape "$NATIVE_CMD")

# Opt-in WebRTC path, mirroring fteqw-server's own SV_PORT_RTC/
# NET_ICE_BROKER (set once from the same .env vars in docker-compose.yml,
# same "set once, passed to both services" convention as GAMEDIRS/
# BASE_GAMEDIR) - see the README's WebRTC section. When SV_PORT_RTC is
# blank (default), brokerConnect is null in config.json and site/app.js
# falls back to exactly today's "+connect wsUrl" behavior.
BROKER_CONNECT_JSON="null"
if [ -n "${SV_PORT_RTC:-}" ]; then
    BROKER_CONNECT_JSON="\"$(json_escape "$SV_PORT_RTC")\""
fi
export BROKER_CONNECT_JSON
export ICE_BROKER_JSON="\"$(json_escape "${NET_ICE_BROKER:-}")\""

# config.base.json holds everything in config.json except "playerName",
# "password", "gameFiles" and "gamedirs", which nginx/auth.js fills in
# per-request from the client's own Basic Auth credentials, the PASSWORD
# env var, and the /paks volume's actual contents respectively - see
# nginx.conf's "location = /config.json".
envsubst '${WS_URL} ${CLIENT_ARGS_JSON} ${NATIVE_CMD_JSON} ${BROKER_CONNECT_JSON} ${ICE_BROKER_JSON}' \
    < /etc/cloudyquake/config.base.json.template > /etc/cloudyquake/config.base.json

exec nginx -g 'daemon off;'
