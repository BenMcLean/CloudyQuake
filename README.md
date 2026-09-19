# CloudyQuake

Multiplayer QuakeWorld, playable straight in the browser, pointed at your own
dedicated server. For the people you invite to play: no client install, no
router config, just a URL and a password. Everything here is open source and
packaged as a docker-compose stack, in the same spirit as
[CloudyDoom](https://github.com/BenMcLean/cloudydoom).

That "no setup" experience is only true for players - **you, running the
server, still need to expose it to the internet**, same as hosting any other
self-hosted service. See
[Putting this behind a reverse proxy / TLS](#putting-this-behind-a-reverse-proxy--tls)
for the concrete setup and exactly what that means for your router.

Native QuakeWorld clients (fteqw, or any other QW-compatible engine) can also
connect directly to the same server and play alongside the browser players -
see [Connecting](#connecting) below.

This is a **private, invite-only** server by design (`SV_PUBLIC=0`,
password-gated) - it's meant to be run with your own legally-owned retail
`pak0.pak`/`pak1.pak`, not the shareware-only subset. See
[Getting paks](#getting-paks).

## How it works

```
  Browser (fteqw's Emscripten/WebGL port)      Native fteqw/QW client
        |                                             |
        | HTTP                                        |
        v                                              |
   +---------+                                         |
   |  nginx  |   (Basic Auth; serves the web client    |
   +---------+    + pak0.pak/pak1.pak)                 |
        |                                              |
        | WS                                           | UDP
        v                                              |
   +---------------+                                   |
   | fteqw-server  | <---------------------------------+
   +---------------+
   (real QuakeWorld dedicated server -
    speaks WebSocket natively, no
    separate translator needed)
```

Unlike [CloudyDoom's architecture](https://github.com/BenMcLean/cloudydoom#how-it-works),
there's no separate "gateway" service translating WebSocket to UDP - fteqw's
dedicated server has WebSocket support built in (`sv_port_tcp`, see fteqw's
own `specs/hosting.txt`/`specs/browser.txt`), so `fteqw-server` is directly
what both browser and native clients connect to.

Two services, three published ports:

| Service | What it is | Port |
|---|---|---|
| `nginx` | Serves the web client (fteqw's own Emscripten/WebGL port, built from [`fte-team/fteqw`](https://github.com/fte-team/fteqw), fetched at build time - see `FTEQW_REF`) behind HTTP Basic Auth. Also serves `pak0.pak`/`pak1.pak`, so the auth gate covers your retail data too. | `WEB_HTTP_PORT` (default `8080`, tcp) |
| `fteqw-server` | A real, unmodified fteqw dedicated server (built from the same pinned `FTEQW_REF`), running standard QuakeWorld gamecode compiled from fteqw's own openly-licensed `quakec/basemod` at build time. Unlike CloudyDoom's `doom-server`, this one *is* authoritative and actually loads your pak data to run the game - see [Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers). | `SV_PORT` (default `27500`, **udp**, native clients) and `SV_PORT_TCP` (default `27500`, tcp, WebSocket/browser clients) |

## Quick start

```
git clone <this repo's URL>
cd cloudyquake
cp .env.example .env
$EDITOR .env   # set CLOUDYQUAKE_WS_URL at minimum, and PASSWORD for a real deployment
mkdir -p paks && cp /path/to/your/pak0.pak /path/to/your/pak1.pak paks/   # see "Getting paks" below
docker compose up -d --build
```

Then open `http://<host>:8080` (or whatever `WEB_HTTP_PORT` you set), log in
with any username and the shared password, and play - the username you type
becomes your in-game player name.

### Configuration

Everything is configured via environment variables at container start, not
baked into any image - see `.env.example` for the full list with defaults.
The one you can't skip:

- `CLOUDYQUAKE_WS_URL` - the websocket URL browsers will connect to. Has to
  be reachable from wherever your players actually are (not just inside the
  docker network). If you're fronting this with a reverse proxy/TLS
  terminator (recommended - see below), point this at that proxy instead of
  directly at `SV_PORT_TCP`.

And one you should set unless you have a specific reason not to:

- `PASSWORD` - gates both the web login (and pak downloads) and joining the
  QuakeWorld server itself. See `.env.example`'s comment on it for why one
  password covers both. The username at login is never checked - anyone can
  pick any username, and it becomes their in-game player name.
- `USE_LOGIN_NAME` - set to `false` to stop using the login username as the
  in-game player name. Combined with a blank `PASSWORD`, setting this to
  `false` too drops the login prompt entirely - players go straight into the
  game.

`.env.example` opens with a "one with everything" block listing every
supported var in one place - copy that instead of hunting through the rest
of the file for exact names, then delete whatever you don't need.

## Getting paks

You need `pak0.pak` (and, for the full game rather than just the shareware
episode, `pak1.pak`) dropped into `paks/` (or wherever `PAK_DIR` points)
before the game will actually run. Unlike CloudyDoom's dedicated server,
**`fteqw-server` does load this data itself** - see
[Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers) -
so it needs to be present before the server can start a map.

This project is built around using your own legally-owned retail copy (from
the original CD, Steam, GOG, etc.) - copy `pak0.pak` and `pak1.pak` out of
your install's `id1/` folder. `PASSWORD`/`SV_PUBLIC=0` exist specifically so
you can do this safely for a private server you control access to; the
freely-redistributable shareware `pak0.pak` alone also works fine if that's
all you have, just without episodes 2-4 or deathmatch levels beyond `dm3`
(check what's actually in your shareware `pak0.pak` - the exact map/content
set has varied across releases).

`PAK_DIR` is mounted **read-only** into both containers - neither can write
to it. On a real Linux host, `nginx` also needs to actually be able to
*read* whatever's in that directory: it runs as its own built-in `nginx`
user (uid/gid 101) by default, which won't be able to read a directory owned
by, say, a dedicated media/homelab user on your system. If you hit a
permission error here, set `PUID`/`PGID` in `.env` to match that directory's
actual owner - see `.env.example`.

## Connecting

- **Browser**: open `http://<host>:<WEB_HTTP_PORT>`, log in, play.
- **Native fteqw/QuakeWorld client**: connect straight to `fteqw-server`'s
  UDP port, bypassing `nginx` entirely - e.g. `fteqw +set password
  "<PASSWORD>" +connect <host>:<SV_PORT>`. Lands in the same game as the
  browser players, since it's talking to the exact same dedicated server.
  `nginx`'s `/config.json` also exposes a ready-to-paste `nativeClientCmd`
  field for this (`curl -u <user>:<pass> https://<host>/config.json`, or
  view it in a browser tab once logged in) - it's there purely for humans to
  read, the browser client itself never looks at it.

## Putting this behind a reverse proxy / TLS

**This compose file does not terminate TLS.** HTTP Basic Auth sends
credentials in the clear, and browsers flatly refuse to open a plain `ws://`
connection from a page loaded over `https://` ("mixed content" blocking -
not a warning, a hard failure). So for anything beyond local testing, both
`nginx` and `fteqw-server`'s WebSocket port need to sit behind something
that terminates TLS.

The setup this project is designed around uses **two separate domains**,
because the web client and the game traffic have very different latency
requirements:

- **`quake.example.com`** (or whatever hostname you pick) - Cloudflare's
  proxy (orange-cloud DNS) in front, serving the web client and paks. This is
  ordinary HTTP(S) traffic with no latency sensitivity, so routing it through
  Cloudflare's remote edge is fine.
- **`quakeworld.example.com`** - a plain, unproxied ("grey-cloud"/DNS-only) A
  record pointing straight at your home IP, for the WebSocket game traffic
  (and, separately, `fteqw-server`'s raw UDP port for native clients, which
  can't go through any HTTP-based reverse proxy at all). Routing real-time
  game traffic through a remote CDN edge adds a real round-trip that a direct
  connection doesn't have - worth avoiding even though Cloudflare's proxy is
  technically capable of carrying WebSocket traffic.

That second hostname still needs TLS for the `wss://` requirement above,
without introducing the latency a remote proxy would. If you're already
running **nginx-proxy-manager** (or Caddy, Traefik, etc.) locally on that
same server for your other self-hosted apps, that's the right tool for this
too - it's a local hop (microseconds), nothing like Cloudflare's geographic
round-trip, and it gets you automatic Let's Encrypt certs for free.

### Configuring nginx-proxy-manager

Add two Proxy Hosts (NPM's "Hosts → Proxy Hosts → Add Proxy Host"):

1. **The website**, if it isn't already behind Cloudflare directly:
   - Domain: `quake.example.com`
   - Forward to: `<your-server's-LAN-IP>:8080` (or the `nginx` container's
     name/port if NPM shares a Docker network with this stack)
   - Request a new SSL certificate, force SSL - standard stuff.

2. **The WebSocket server** - this is the one with a step that's easy to
   miss:
   - Domain: `quakeworld.example.com`
   - Forward to: `<your-server's-LAN-IP>:27500` (or whatever `SV_PORT_TCP`
     you set)
   - On the **Details** tab, enable **"Websockets Support"**. Without this,
     NPM won't forward the `Upgrade`/`Connection` headers the WebSocket
     handshake needs, and every browser client will fail to connect with no
     obvious error pointing at NPM as the cause.
   - Request a new SSL certificate here too, force SSL.

Then set `CLOUDYQUAKE_WS_URL=wss://quakeworld.example.com` in `.env` - no
custom port needed, since NPM terminates `443` and forwards internally to
`fteqw-server`'s `SV_PORT_TCP`.

**`SV_PORT` (raw UDP, for native clients) can't go through NPM either** -
nginx-based reverse proxies are HTTP(S)/WebSocket-only, the same fundamental
limitation as Cloudflare's standard proxy, just for a config reason rather
than a product-tier one. Forward it straight through your router to
`fteqw-server`, same as you would for any other UDP game server.

## Troubleshooting

- **Browser client connects then immediately gets kicked/rejected**: check
  `PASSWORD` matches between `.env`'s single shared value and what you typed
  at the login prompt - `nginx/auth.js` hands the same secret to the
  already-authenticated browser via `/config.json` for it to send as
  `+password`, so a mismatch here usually means stale `.env` values from
  before a `docker compose up` that didn't rebuild.
- **WebSocket connection fails only through the reverse proxy, works fine
  hitting the container's port directly**: almost always the "Websockets
  Support" toggle in nginx-proxy-manager (or the equivalent
  `proxy_set_header Upgrade`/`Connection` directives in a hand-written nginx
  config) - see [Configuring nginx-proxy-manager](#configuring-nginx-proxy-manager)
  above.

## Why the pak volume is mounted into both containers

Doom's netcode is a deterministic lockstep model - every client simulates
the game itself, and `chocolate-server` (CloudyDoom's dedicated server) is a
pure netcode sequencer that never even looks at the WAD. QuakeWorld is
different: it's a genuine client-server model where the server is
authoritative and actually runs the game simulation, so `fteqw-server` needs
real access to the map/model/sound data in `pak0.pak`/`pak1.pak` to do that -
not just `nginx`, which only needs them to hand out to browsers.

## Credits / license

- [`fte-team/fteqw`](https://github.com/fte-team/fteqw) - the QuakeWorld
  engine (with an Emscripten/WebGL web port and native WebSocket support
  built in) this is built on, fetched at build time from a pinned tag (see
  `FTEQW_REF` in `nginx/Dockerfile` and `fteqw-server/Dockerfile`) rather
  than vendored, since it's used entirely unmodified here.
- The dedicated server's gamecode is compiled from fteqw's own
  `quakec/basemod` - see its `basemod.txt` for license terms. The actual
  game data (maps, models, textures, sounds) always comes from your own pak
  volume, never baked into any image here.
