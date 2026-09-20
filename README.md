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

Private and unlisted by default (`sv_public` isn't set to advertise, which
is fteqw's own default unless you explicitly add `+set sv_public 1` to
`SERVER_ARGS`) and password-gated. The actual game content (`pak0.pak`, optionally
`pak1.pak`, or any QuakeC mod's own paks) is a docker volume, same as
CloudyDoom's WAD directory - see [Getting paks](#getting-paks) for what goes
in it, it's entirely up to you.

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
| `nginx` | Serves the web client (fteqw's own Emscripten/WebGL port, built from [`fte-team/fteqw`](https://github.com/fte-team/fteqw), fetched at build time - see `FTEQW_REF`) behind HTTP Basic Auth. Also serves your pak files, so the auth gate covers those too. | `WEB_HTTP_PORT` (default `8080`, tcp) |
| `fteqw-server` | A real, unmodified fteqw dedicated server (built from the same pinned `FTEQW_REF`), running standard QuakeWorld gamecode compiled from fteqw's own openly-licensed `quakec/basemod` at build time. Unlike CloudyDoom's `doom-server`, this one *is* authoritative and actually loads your pak data to run the game - see [Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers). | `SV_PORT` (default `27500`, **udp**, native clients) and `SV_PORT_TCP` (default `27500`, tcp, WebSocket/browser clients) |

## Supported games

`GAME` (default `qw`) picks which game the `fteqw-server` image is actually
*built* for, as well as which engine-mode flag `docker-entrypoint.sh` forces
on at startup - see `fteqw-server/Dockerfile`. Changing it needs a rebuild
(`docker compose up -d --build`), not just a restart, since it changes what
gamecode gets compiled into the image.

`SERVER_ARGS` is a raw passthrough of fteqw's own dedicated-server command
line switches/cvars on top of whatever `GAME` already forced on, so
anything fteqw itself supports via its own flags is fair game, not just
what this README happens to call out - the one exception is the
engine-mode switch itself (`-game qw` or `-quake2`), which `GAME` always
forces on rather than something you set in `SERVER_ARGS`.

`BASE_GAMEDIR` (default `id1`) is the one CloudyQuake-specific concept
alongside these two - purely which `PAK_DIR` subfolder gets treated as
fteqw's implicit always-loaded gamedir, matching whatever real retail
install layout the game you're running actually uses. None of `GAME`,
`SERVER_ARGS`, or `BASE_GAMEDIR` maps the others for you; they just need to
agree, same as they would running fteqw natively outside Docker.

**QuakeWorld** (the default: `GAME=qw`, `BASE_GAMEDIR=id1`, `SERVER_ARGS`
unset) - the one game this stack bakes gamecode for, compiled from fteqw's
own openly-licensed `quakec/basemod` into the `fteqw-server` image at
build time (see [Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers)).
QuakeWorld was never part of any retail Quake release, so there's nothing
to source this gamecode from other than compiling it - everything else
below instead comes entirely from your own pak volume, same as any
`GAMEDIRS` entry.

**Hexen II** (`GAME=qw`, `SERVER_ARGS=-hexen2`, `BASE_GAMEDIR=data1`) -
fteqw's own docs describe this as FTE treating Hexen II as "a glorified
mod" of the exact same QuakeC VM and QuakeWorld-style netcode/protocol,
just against a different base gamedir and a flag telling the engine which
game's rules/defaults to use - so it needs no separate build or fork here
either, and runs under the same `GAME=qw` image as stock QuakeWorld. Its
gamecode comes entirely from your own pak volume: the base game's
`progs.dat` ships packed inside retail `pak0.pak`/`pak1.pak`, and the
Portal of Praevus mission pack (`GAMEDIRS=portals`) ships an improved one
as a loose file - both get picked up automatically, nothing baked into the
image. See [Getting paks](#getting-paks) below for the exact layout.
Remember to add `-hexen2` to `CLIENT_ARGS` too, so the browser client's own
fteqw build runs in the same mode (see `.env.example`).

**Quake II** (`GAME=quake2`, `BASE_GAMEDIR=baseq2`) - supported via
[Yamagi Quake II](https://github.com/yquake2/yquake2) (GPLv2, pinned to a
fixed release tag in `fteqw-server/Dockerfile`): unlike QuakeWorld/Hexen
II's QuakeC, Quake II's gamecode is a natively-compiled shared library (id
Tech 2's game DLL ABI) that fteqw `dlopen()`s at runtime rather than
bundling itself, so `GAME=quake2` builds one from yquake2's `src/game/` -
just the gamecode, not its client/server/renderer, which this project has
no use for - and bakes it into the `fteqw-server` image the same general
way `quakec/basemod` is baked in for QuakeWorld. `BASE_GAMEDIR=baseq2`
matters here beyond the usual pak-volume convention: the baked gamecode
library's own filename embeds that exact gamedir name, so it has to match.
Remember to add `-quake2` to `CLIENT_ARGS` too, same as Hexen II's
`-hexen2` above.

Quake II ships player models/skins (`players/`) as **loose files**, not
packed into any pak, unlike QuakeWorld/Hexen II - copy that folder over
as-is alongside the paks (see [Getting paks](#getting-paks)) or players
will spawn with missing models. Don't bother copying
`gamex86.dll`/`gamex86_64.dll` if your install has one - that's the
original Windows native gamecode DLL, irrelevant here since `GAME=quake2`
builds and bakes in its own Linux one.

Quake III is **not supported yet**. fteqw does have Quake III support, but
as a separate optional plugin, and Quake III's gamecode is split into three
modules (`game`, plus client-side `cgame`/`ui`) rather than Quake II's
server-only one - a similar general shape (dlopen'able native or QVM
bytecode gamecode, GPLv2 source available from `ioquake3`) but with enough
extra moving parts that it's being left for later rather than folded into
this pass.

## Quick start

```
git clone <this repo's URL>
cd cloudyquake
cp .env.example .env
$EDITOR .env   # set WS_URL at minimum, and PASSWORD for a real deployment
mkdir -p paks/id1 && cp /path/to/your/pak0.pak /path/to/your/pak1.pak paks/id1/   # see "Getting paks" below - data1/ instead of id1/ for Hexen II
docker compose up -d --build
```

Then open `http://<host>:8080` (or whatever `WEB_HTTP_PORT` you set), log in
with any username and the shared password, and play - the username you type
becomes your in-game player name.

### Configuration

Everything is configured via environment variables at container start, not
baked into any image - see `.env.example` for the full list with defaults.
The one you can't skip:

- `WS_URL` - the websocket URL browsers will connect to. Has to
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

You need `id1/pak0.pak` (and, for the full game rather than just the
shareware episode, `id1/pak1.pak`) inside `paks/` (or wherever `PAK_DIR`
points) before the game will actually run - or `data1/pak0.pak`/`pak1.pak`
if you've set `BASE_GAMEDIR=data1` for Hexen II, or `baseq2/pak0.pak` for
`GAME=quake2`/`BASE_GAMEDIR=baseq2` (see
[Supported games](#supported-games)). Unlike CloudyDoom's dedicated
server, **`fteqw-server` does load this data itself** - see
[Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers) -
so it needs to be present before the server can start a map.

`PAK_DIR` is a plain docker volume laid out the same way a real install of
whichever game you're running already is - one subfolder per gamedir. For
the default (`BASE_GAMEDIR=id1`, stock Quake/QuakeWorld):

```
paks/
  id1/pak0.pak        <- required, the base game
  id1/pak1.pak        <- optional, full registered game instead of shareware
  hipnotic/pak0.pak   <- an official mission pack
  mymappack/pak0.pak  <- your own map pack, mod, or anything else
```

...or for Hexen II (`BASE_GAMEDIR=data1`):

```
paks/
  data1/pak0.pak       <- required, the base game
  data1/pak1.pak       <- optional, full registered game instead of shareware
  portals/pak3.pak     <- the Portal of Praevus mission pack (GAMEDIRS=portals)
```

...or for Quake II (`GAME=quake2`, `BASE_GAMEDIR=baseq2` - see
[Supported games](#supported-games)):

```
paks/
  baseq2/pak0.pak      <- required, the base game
  baseq2/pak1.pak      <- required, day-one patch data merged into retail/GOG/Steam copies
  baseq2/pak2.pak      <- required, same as above
  baseq2/players/      <- required, player models/skins - Quake II ships these as loose
                          files (not packed into any pak), unlike QuakeWorld/Hexen II,
                          so this folder needs copying over as-is from your own install
  baseq2/maps/          <- optional, if any loose (unpacked) map files exist outside the paks
```

Gamedir folder names and `*.pak`/`*.pk3` filenames inside `PAK_DIR` are
matched **case-insensitively** - a Windows/GOG/Steam install's
`Id1/PAK0.PAK` works exactly the same as `id1/pak0.pak`, so you can point
`PAK_DIR` straight at a copied install folder without renaming anything.

The base gamedir (`BASE_GAMEDIR`, `id1/` by default) is always loaded.
`GAMEDIRS` stacks any number of further gamedirs on top, in order (e.g.
`GAMEDIRS="hipnotic mymappack"` for Scourge of Armagon plus a custom map
pack over it, or `GAMEDIRS="portals"` for Hexen II's own mission pack) - a
mission pack, a total conversion, a QuakeC mod, anything that follows
Quake's own `-game <gamedir>` convention (fteqw supports up to 8 stacked
gamedirs total). What goes in any of these folders is entirely up to you,
same as CloudyDoom's `WAD_DIR`:

- Your own copy of `pak0.pak`/`pak1.pak` (from the original CD, Steam, GOG,
  etc.), copied out of your install's base gamedir, for the full game.
- The freely-redistributable shareware Quake `pak0.pak` alone, if that's
  all you have or all you want to offer (stock Quake only - Hexen II has
  no equivalent shareware release) - works fine, just without episodes 2-4
  or deathmatch levels beyond `dm3` (check what's actually in your copy -
  the exact map/content set has varied across releases).
- The official mission packs (`hipnotic/`, `rogue/`, or Hexen II's
  `portals/`) or a third-party QuakeC mod's own gamedir, via `GAMEDIRS`.

Whatever you use, it's your own responsibility to have the rights to serve
it to whoever you invite - `PASSWORD` and `SV_PUBLIC=0` just keep it off the
public internet/server browser by default, they're not a substitute for
that.

Every file anywhere inside `id1/` or a gamedir folder you've listed in
`GAMEDIRS` - however deeply nested - is served to the browser client
(found dynamically per-request by `nginx/auth.js` - drop a new file in,
at any depth, and it's picked up without a restart): packed
`pak0.pak`/`pak1.pak`/etc., a mod's own loose `config.cfg`/`autoexec.cfg`,
loose maps/textures/sounds under `maps/`/`sound/`/etc. (common when a
mod's own maps were distributed separately by different map authors rather
than bundled into one pak), or anything else. There's no extension or
depth whitelist: only folders you've actually opted into (`id1/` plus
whatever's in `GAMEDIRS`) get listed at all, so what's in them is already
your call, same as it is for `fteqw-server`, which loads everything in
those same folders regardless of type or nesting.

**A standalone map or small map pack usually doesn't need any of this at
all**, even now that loose files are served proactively. fteqw also
auto-downloads any map a connecting client doesn't already have, straight
from `fteqw-server` over the game connection itself (see fteqw's own
`specs/browser.txt`) - so just dropping extra `.bsp` files into an
already-loaded gamedir's `maps/` folder (e.g. `paks/id1/maps/mymap.bsp`)
works with no pak, no `GAMEDIRS` entry, and no nginx involvement, for both
web and native clients. Reach for a dedicated `GAMEDIRS` entry instead when
a map pack ships its own textures/models/sounds bundled as a pak, or you
specifically want it toggleable independently of `id1/`.

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

Then set `WS_URL=wss://quakeworld.example.com` in `.env` - no
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
real access to the map/model/sound data in your paks to do that - not just
`nginx`, which only needs them to hand out to browsers.

On the `fteqw-server` side specifically, `PAK_DIR` isn't bind-mounted
straight onto its basedir (`/fte`) - that basedir also holds a `qw/` folder
baked into the image at build time (fteqw's own compiled QuakeWorld
gamecode, see [Credits / license](#credits--license)), and a bind mount
would hide that entirely rather than merge with it. Instead it's mounted at
`/fte-data`, and `docker-entrypoint.sh` symlinks each gamedir subfolder it
finds there into `/fte/` at container start - so a `paks/qw/` of your own
(e.g. copied from a full retail install) still takes priority over the
built-in one, instead of silently failing to appear at all.

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
