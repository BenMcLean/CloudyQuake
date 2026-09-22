#!/bin/sh
set -eu

# Same stdout-buffering fix as fteqw-server/docker-entrypoint.sh - under
# Docker, stdout is never a TTY, so C's stdio would otherwise sit fully
# buffered and never reach `docker logs`.
FTEMASTER_PORT="${FTEMASTER_PORT:-27950}"

exec stdbuf -oL -eL /usr/local/bin/ftemaster \
    +set sv_masterport_tcp "$FTEMASTER_PORT"
