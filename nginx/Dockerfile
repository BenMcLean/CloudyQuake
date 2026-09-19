# Build context is expected to be the repo root, e.g.:
#   docker build -f nginx/Dockerfile .
# (matches CloudyDoom's nginx/Dockerfile convention, even though this one
# doesn't actually need any sibling files outside nginx/ - fteqw is fetched
# at build time rather than vendored, same as fteqw-server/Dockerfile.)

# --- Stage 1: compile ftewebgl.{js,wasm} from fteqw's web/Emscripten port ---
FROM emscripten/emsdk:2.0.12 AS wasm-builder

# Pinned to match both fteqw-server/Dockerfile's FTEQW_REF (so the web
# client and the dedicated server are always built from the exact same
# source) and the emsdk version fteqw's own CI workflow verifies against
# (.github/workflows/main.yml's "web" matrix entry) - don't bump one
# without checking the other still builds.
ARG FTEQW_REF=2025-09-27

RUN git clone --depth 1 --branch "$FTEQW_REF" https://github.com/fte-team/fteqw.git /src

WORKDIR /src/engine
# The "web" FTE_TARGET uses browser-native loaders for audio/image
# decoding instead of building its own copies from source (see
# engine/Makefile's comment on FTE_TARGET=web), so no extra system
# packages are needed here beyond what the emsdk base image already has.
RUN make FTE_TARGET=web makelibs \
    && make -j"$(nproc)" FTE_TARGET=web gl-rel

# --- Stage 2: serve the compiled client behind Basic Auth ---
FROM nginx:1.27-alpine

RUN apk add --no-cache gettext nginx-mod-http-js

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/auth.js /etc/nginx/njs/auth.js
COPY nginx/config.base.json.template /etc/cloudyquake/config.base.json.template
COPY nginx/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY nginx/site/ /usr/share/nginx/html/
COPY --from=wasm-builder /src/engine/release/ftewebgl.js /usr/share/nginx/html/
COPY --from=wasm-builder /src/engine/release/ftewebgl.wasm /usr/share/nginx/html/

# Mount point for the pak volume - see PAK_DIR in docker-compose.yml.
RUN mkdir -p /paks

# The compose file can run this container as an arbitrary PUID/PGID (see
# docker-compose.yml's "user:" and PUID/PGID) so nginx can read a /paks
# volume owned by whatever uid your host uses - not just the default nginx
# user (101). These are the paths that uid needs to be able to write to
# regardless of which one it ends up being: nginx's own runtime files, and
# config.base.json, which the entrypoint generates at container start (see
# CONFIG_BASE_PATH there). None of this is sensitive - it's all
# container-internal generated config, not the /paks mount itself, which
# stays read-only and under your own control on the host.
RUN chmod 777 /var/cache/nginx /run /etc/nginx /etc/cloudyquake

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
