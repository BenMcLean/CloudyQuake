# CloudyQuake

Multiplayer QuakeWorld (and friends), playable straight in the browser and
hosted on your own dedicated server. For the people you invite to play: no
client install, no router config, just a URL and a password. Everything here
is open source and runs as a docker-compose stack.

The "no setup" experience is only true for players - **you, running the
server, still need to expose it to the internet**, same as hosting any other
self-hosted service. [Deploying](#deploying) lists every hostname and port
involved in one place.

Native QuakeWorld clients (fteqw, or any other QW-compatible engine) can also
connect directly to the same server and play alongside the browser players -
see [Connecting](#connecting).

The server is private and unlisted by default (fteqw's own `sv_public`
default, unless you add `+set sv_public 1` to `SERVER_ARGS`) and
password-gated. The actual game content (`pak0.pak`, optionally `pak1.pak`,
or any QuakeC mod's own paks) is a docker volume that you fill yourself - see
[Getting paks](#getting-paks).

## How it works

```
 1. Everyone loads the web client:

      Browser --HTTPS--> nginx        (Basic Auth; serves the client + paks)

 2. Then the browser plays over ONE of these, chosen by the admin
    (NET_ICE_BROKER set = A, blank = B):

    A. WebRTC - UDP, lower latency under packet loss (recommended)

      Browser --WSS--> ftemaster <--WSS-- fteqw-server
                        (the broker only relays connection info;
                         it never sees game traffic)

      Browser <=======UDP, direct======> fteqw-server

    B. WebSocket - TCP, works on any network (alternative)

      Browser --WSS--> fteqw-server

 3. Native fteqw/QuakeWorld clients skip all of the above:

      Native client --UDP--> fteqw-server
```

`fteqw-server` is a real QuakeWorld dedicated server that speaks WebRTC,
WebSocket and plain UDP natively, so no separate translator service is
needed. It is authoritative and actually loads your pak data to run the game -
see [Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers).

Three services:

| Service | What it is |
|---|---|
| `nginx` | Serves the web client (fteqw's own Emscripten/WebGL port, built from [`fte-team/fteqw`](https://github.com/fte-team/fteqw) at build time - see `FTEQW_REF`) behind HTTP Basic Auth. Also serves your pak files, so the auth gate covers those too. |
| `fteqw-server` | A real, unmodified fteqw dedicated server (built from the same pinned `FTEQW_REF`), running standard QuakeWorld gamecode compiled from fteqw's own openly-licensed `quakec/basemod`. Serves WebRTC, WebSocket and native UDP clients. |
| `ftemaster` | The WebRTC/ICE broker (fteqw's own `ftemaster` binary). Only relays the handshake that lets browsers and `fteqw-server` find each other. Runs either way but does nothing unless you set `NET_ICE_BROKER`. |

Ports and hostnames are all in [Deploying](#deploying).

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

### Quake (1996)

**QuakeWorld** (the default: `GAME=qw`, `BASE_GAMEDIR=id1`, `SERVER_ARGS`
unset) - the one game this stack bakes gamecode for, compiled from fteqw's
own openly-licensed `quakec/basemod` into the `fteqw-server` image at
build time (see [Why the pak volume is mounted into both containers](#why-the-pak-volume-is-mounted-into-both-containers)).
QuakeWorld was never part of any retail Quake release, so there's nothing
to source this gamecode from other than compiling it - everything else
below instead comes entirely from your own pak volume, same as any
`GAMEDIRS` entry.

#### Hexen II (1997)

fteqw's own docs describe treating Hexen II as "a glorified mod" of the exact same
QuakeC VM and QuakeWorld-style netcode/protocol, just against a different
base gamedir
(`GAME=qw`, `SERVER_ARGS=-hexen2`, `BASE_GAMEDIR=data1`) and a flag telling
the engine which game's rules/defaults to use - so it needs no separate
build or fork here either, and runs under the same `GAME=qw` image as
stock QuakeWorld. Its gamecode comes entirely from your own pak volume:
the base game's `progs.dat` ships packed inside retail
`pak0.pak`/`pak1.pak`, and the Portal of Praevus mission pack
(`GAMEDIRS=portals`) ships an improved one as a loose file - both get
picked up automatically, nothing baked into the image. See
[Getting paks](#getting-paks) below for the exact layout. Remember to add
`-hexen2` to `CLIENT_ARGS` too, so the browser client's own fteqw build
runs in the same mode (see `.env.example`).

### Quake II (1997)

The base game (`GAME=quake2`, `BASE_GAMEDIR=baseq2`) is supported via
[Yamagi Quake II](https://github.com/yquake2/yquake2) (GPLv2, pinned to a
fixed release tag in `fteqw-server/Dockerfile`): unlike QuakeWorld/Hexen
II's QuakeC, Quake II's gamecode is a natively-compiled shared library
that fteqw `dlopen()`s at runtime rather than
bundling itself, so `GAME=quake2` builds one from yquake2's `src/game/` -
just the gamecode, not its client/server/renderer, which this project has
no use for - and bakes it into the `fteqw-server` image the same general
way `quakec/basemod` is baked in for QuakeWorld. `BASE_GAMEDIR=baseq2`
matters here beyond the usual pak-volume convention: the baked gamecode
library's own filename embeds that exact gamedir name, so it has to match.
Unlike Hexen II's `-hexen2`, nothing needs adding to `CLIENT_ARGS` for
this - the browser client (and any native client) negotiates the protocol
with the server automatically during connect, confirmed by testing.

Quake II ships player models/skins (`players/`) as **loose files**, not
packed into any pak, unlike QuakeWorld/Hexen II - copy that folder over
as-is alongside the paks (see [Getting paks](#getting-paks)) or players
will spawn with missing models. Don't bother copying
`gamex86.dll`/`gamex86_64.dll` if your install has one - that's the
original Windows native gamecode DLL, irrelevant here since `GAME=quake2`
builds and bakes in its own Linux one.

The following mission packs/mods are supported via `GAMEDIRS`, each a
natively-compiled gamecode library baked in the same way and built from its
own maintained open-source repo (same as `baseq2`'s above), not from
anyone's original closed binary:

| `GAMEDIRS` entry | Mod | Source |
|---|---|---|
| `rogue` | Ground Zero (official mission pack) | [`yquake2/rogue`](https://github.com/yquake2/rogue), GPLv2 |
| `xatrix` | The Reckoning (official mission pack) | [`yquake2/xatrix`](https://github.com/yquake2/xatrix), GPLv2 |
| `ctf` | Capture the Flag (id Software's official mod) | [`yquake2/ctf`](https://github.com/yquake2/ctf), GPLv2 |
| `action` | Action Quake 2 | [`aq2-tng/aq2-tng`](https://github.com/aq2-tng/aq2-tng) - the actual gamecode source behind [AQtion](https://github.com/actionquake/distrib), the mod's actively maintained continuation |

Use them the same way as any other `GAMEDIRS` entry (e.g.
`GAMEDIRS="rogue"`), with the matching pak data in your own `PAK_DIR` (see
[Getting paks](#getting-paks)) - the gamecode itself needs no extra setup,
it's already in the image.

**Known issue: player names don't stick.** A player's chosen name (from the
login prompt, or a native client's own `name`) applies correctly for a
moment at connect - the server log shows `<name> connected` - but gets
reset to blank ("unnamed") shortly after, before the player actually
spawns. Verified with a packet-level capture: the browser client's connect
request genuinely does include the right name; the server even logs it
correctly at that instant. It's the *next* step that loses it - the first
routine post-connect userinfo sync (fteqw's generic, QuakeWorld-era
per-key `setinfo` update mechanism, which fires automatically and isn't
something `SERVER_ARGS`/`CLIENT_ARGS` control) rebuilds the player's
*entire* userinfo string from an internal buffer that Quake II clients
never actually populate (Quake II's own connect handshake sends userinfo
as one raw string instead), silently wiping every key - name included -
back to blank. This is a bug in fteqw itself (confirmed present in this
project's own pinned `FTEQW_REF`), not something fixable from
CloudyQuake's side - see `fte-team/fteqw`'s `engine/server/sv_user.c`
(the `Q2SERVER`-gated branch of its `setinfo` command handler) if you want
to dig into it yourself. Everything else about a match - joining,
playing, chat, scores - works regardless; only the display name is
affected.

### Quake III Arena (1999)

**Not supported yet**. fteqw does have Quake III support, but it is not implemented here yet. Coming soon!

## Quick start

```
git clone <this repo's URL>
cd cloudyquake
cp .env.example .env
$EDITOR .env   # set NET_ICE_BROKER (or WS_URL) at minimum, and PASSWORD for a real deployment
mkdir -p paks/id1 && cp /path/to/your/pak0.pak /path/to/your/pak1.pak paks/id1/   # see "Getting paks" below - data1/ instead of id1/ for Hexen II
docker compose up -d --build
```

Then open `http://<host>:27501` (or whatever `WEB_HTTP_PORT` you set), log in
with any username and the shared password, and play - the username you type
becomes your in-game player name. For anyone other than yourself on a real
network, continue to [Deploying](#deploying) first: you need TLS.

### Configuration

Everything is configured via environment variables at container start, not
baked into any image - see `.env.example` for the full list with defaults.
The ones you can't skip:

- `NET_ICE_BROKER` - turns on WebRTC, the recommended transport. See
  [Deploying](#deploying) for values.
- *or*, as the alternative, `WS_URL` - the public `wss://` URL of
  `fteqw-server`'s WebSocket port, with `NET_ICE_BROKER` left blank. See
  [Alternative: WebSocket only](#alternative-websocket-only).

And the ones you should set unless you have a specific reason not to:

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
[Supported games](#supported-games)). **`fteqw-server` loads this data
itself** - see
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
  rogue/pak0.pak       <- Ground Zero mission pack (GAMEDIRS=rogue) - gamecode already
                          baked in, see Supported games
  xatrix/pak0.pak      <- The Reckoning mission pack (GAMEDIRS=xatrix) - same
  ctf/pak0.pak         <- Capture the Flag (GAMEDIRS=ctf) - same
  action/pak0.pak      <- Action Quake 2 (GAMEDIRS=action) - same, plus its own
                          loose players/ skins the same way baseq2 has
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
gamedirs total). What goes in any of these folders is entirely up to you:

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

- **Browser**: open your site's URL, log in, play.
- **Native fteqw/QuakeWorld client**: connect straight to `fteqw-server`'s
  UDP port, bypassing `nginx` entirely - e.g. `fteqw +set password
  "<PASSWORD>" +connect <host>:<SV_PORT>`. Lands in the same game as the
  browser players, since it's talking to the exact same dedicated server.
  `nginx`'s `/config.json` also exposes a ready-to-paste `nativeClientCmd`
  field for this (`curl -u <user>:<pass> https://<host>/config.json`, or
  view it in a browser tab once logged in) - it's there purely for humans to
  read, the browser client itself never looks at it.

## Deploying

**This compose file does not terminate TLS.** HTTP Basic Auth sends
credentials in the clear, and browsers flatly refuse to open a plain `ws://`
connection from a page loaded over `https://` ("mixed content" blocking -
not a warning, a hard failure). So for anything beyond local testing, the
web site and both WebSocket endpoints need to sit behind something that
terminates TLS. The examples below use **nginx-proxy-manager** (NPM); Caddy,
Traefik or a hand-written nginx work the same way. A local reverse proxy
adds microseconds; it's nothing like routing through a CDN.

> **Status:** the WebRTC setup is worked out from fteqw's source and a
> same-machine Docker test. It has **not** yet been verified end-to-end on a
> real deployment, so check it with `net_ice_debug 2` (below) the first time.

### Hostnames

Register these (replace `example.com`). All point at your server's IP:

| Hostname | Cloudflare | Purpose |
|---|---|---|
| `quake.example.com` | proxied (orange cloud) | Web client and paks |
| `quakebroker.example.com` | DNS-only (grey cloud) | WebRTC broker signaling (`ftemaster`) |
| `quakeserver.example.com` | DNS-only (grey cloud) | The game server's address: where WebRTC's UDP traffic and native clients arrive (and `wss://` in the WebSocket alternative) |

The web site is ordinary HTTP(S) with no latency sensitivity, so Cloudflare's
proxy is fine there. The other two carry real-time traffic, so they stay
unproxied to avoid an extra CDN round-trip (and Cloudflare's proxy can't
carry UDP at all). If you don't use Cloudflare, the distinction doesn't
matter - just point all three at your server.

### Ports

| What | Port | Protocol | Route |
|---|---|---|---|
| Web client + paks | `WEB_HTTP_PORT` (default `27501`) | tcp | router `443` -> NPM -> `nginx` |
| WebRTC broker signaling | `FTEMASTER_PORT` (default `27950`) | tcp | router `443` -> NPM -> `ftemaster` |
| **WebRTC game traffic, native clients** | `SV_PORT` (default `27500`) | **udp** | **router forwards straight to `fteqw-server`** - no proxy can carry UDP |
| WebSocket game traffic (alternative only) | `SV_PORT_TCP` (default `27500`) | tcp | router `443` -> NPM -> `fteqw-server` |

Your router therefore needs: TCP `443` to NPM (you probably have this
already) and **UDP `27500` to the machine running this stack**. Nothing else
needs a forward.

### Reverse proxy (nginx-proxy-manager)

Add one Proxy Host per row ("Hosts -> Proxy Hosts -> Add Proxy Host"). Each
gets a new SSL certificate with force SSL.

| Domain | Forward to | Websockets Support |
|---|---|---|
| `quake.example.com` | `<server LAN IP>:27501` | not needed |
| `quakebroker.example.com` | `<server LAN IP>:27950` | **required** |

For the WebSocket alternative only, add `quakeserver.example.com` ->
`<server LAN IP>:27500` (`SV_PORT_TCP`) with Websockets Support. With WebRTC
that hostname needs no Proxy Host: it just has to resolve to your server so
the UDP forward and native clients can reach it.

**"Websockets Support" (Details tab) is the step that's easy to miss.**
Without it NPM won't forward the `Upgrade`/`Connection` headers the
handshake needs, and every browser client fails to connect with no obvious
error pointing at NPM as the cause. (If NPM shares a Docker network with this
stack you can forward to container names instead of the LAN IP.)

### Configuring WebRTC (recommended)

WebSocket is TCP underneath, so any packet loss stalls *everything* behind
it until the lost packet is retransmitted (head-of-line blocking). WebRTC
carries game traffic over UDP instead, so a lost packet only costs that one
packet. `ftemaster` doesn't touch game traffic at all - it only relays the
ICE/SDP handshake that lets the browser and `fteqw-server` open a direct UDP
path to each other. See fteqw's own `specs/hosting.txt`/`specs/browser.txt`
("WebRTC / ICE").

`.env`:

```
NET_ICE_BROKER=wss://quakebroker.example.com/
SV_HOST=quakeserver.example.com
SERVER_ARGS=... +set net_ice_servers stun:stun.l.google.com:19302
CLIENT_ARGS=+set net_ice_servers stun:stun.l.google.com:19302
```

- `NET_ICE_BROKER` - the public URL browsers use to reach the broker
  (through NPM, on `443`). **Setting it is what switches the browser from
  WebSocket to WebRTC.** `fteqw-server` itself always talks to the bundled
  `ftemaster` directly over the container network, so there's no matching
  setting for that side.
- `NET_ICE_NAME` - optional, default `/cloudyquake`. The name `fteqw-server`
  registers with the broker; clients then `connect /cloudyquake`. Only
  change it if you run several servers on one broker. This is fteqw's
  `sv_port_rtc` cvar
  (**RTC, not RTP** - fteqw's `specs/hosting.txt` says `sv_port_rtp`, but
  that cvar doesn't exist in the source; an upstream doc typo).
- `SV_HOST` - optional; the hostname shown in the ready-to-paste native
  client command. Must resolve to the server's UDP port.
- `net_ice_servers` supplies a real STUN server to both sides. Normally
  fteqw uses the broker itself as STUN, derived from the broker URL's host and
  port - but behind NPM that lands on a port nothing answers UDP on, and the
  server (which reaches `ftemaster` over Docker's private network) would learn
  a private address instead of your public one. Any public STUN server works;
  use your own if you'd rather not depend on Google's.

All of these are read once and passed to `fteqw-server`, `ftemaster`, *and*
`nginx` (for the browser client) - see `docker-compose.yml`.

**Check it.** Add `+set net_ice_debug 2` to `SERVER_ARGS`/`CLIENT_ARGS`, load
the site, and look at `docker compose logs fteqw-server`: you should see
`Publicly listening on /myserver`, the browser's candidates, your public IP as
the server's `Public address`, and finally `ice state connected`. If it stays
on "Waiting for broker connection" the broker Proxy Host (or its Websockets
toggle) is the problem; if it reaches `connecting` but times out, UDP `27500`
isn't reaching the server.

If your players' networks block UDP, WebRTC can't work for them and there is
no automatic fallback - use the WebSocket alternative below for everyone.

### Alternative: WebSocket only

Simpler, works on any network, but subject to the TCP stalls described
above. Leave `NET_ICE_BROKER` blank, and set:

```
WS_URL=wss://quakeserver.example.com
```

You then don't need the `quakebroker` hostname, its Proxy Host, or the broker
port (the `ftemaster` service still starts but sits idle). The UDP `27500`
forward is only needed for native clients.

### Testing WebRTC locally in Docker Desktop

Works, with a local-only wrinkle or two:

- Set `NET_ICE_BROKER=ws://localhost:27950/` so the browser can reach the
  broker (the server finds it on its own).
- By default Chrome hides its LAN IP behind an mDNS `.local` name, which a
  container can't resolve, so ICE has no address to check. Start Chrome
  with `--disable-features=WebRtcHideLocalIpsWithMdns` for local testing
  (real deployments don't need this - browsers' public addresses come from
  STUN).
- `+set net_ice_debug 2` in `SERVER_ARGS`/`CLIENT_ARGS` shows every
  candidate and connectivity check in `docker compose logs fteqw-server`
  and the browser console.

## Troubleshooting

- **Browser client connects then immediately gets kicked/rejected**: check
  `PASSWORD` matches between `.env`'s single shared value and what you typed
  at the login prompt - `nginx/auth.js` hands the same secret to the
  already-authenticated browser via `/config.json` for it to send as
  `+password`, so a mismatch here usually means stale `.env` values from
  before a `docker compose up` that didn't rebuild.
- **Connection fails only through the reverse proxy, works fine hitting the
  container's port directly**: almost always the "Websockets Support" toggle
  in nginx-proxy-manager (or the equivalent `proxy_set_header
  Upgrade`/`Connection` directives in a hand-written nginx config) on the
  broker or game-server host - see [Reverse proxy](#reverse-proxy-nginx-proxy-manager).
- **WebRTC connect fails/times out**: check, in order:
  1. `docker compose logs fteqw-server` should show `Publicly listening on
     /<name>`. If it doesn't, the server never registered with the broker
     (see the `tcp://`/trailing-slash note above).
  2. Set `net_ice_debug 2` and look at the candidates the server logs. If
     the browser only offers `.local` (mDNS) and Docker-gateway addresses,
     it's the local Docker Desktop case above.
  3. The broker's Proxy Host needs "Websockets Support" enabled.
  4. `SV_PORT` (udp) must be forwarded through your router straight to
     `fteqw-server`, and both sides need a reachable STUN server - see
     [Configuring WebRTC](#configuring-webrtc-recommended).

## Why the pak volume is mounted into both containers

QuakeWorld is a genuine client-server model: the server is authoritative and
actually runs the game simulation, so `fteqw-server` needs real access to the
map/model/sound data in your paks to do that - not just `nginx`, which only
needs them to hand out to browsers.

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

## Other Projects

- [CloudyDoom](https://github.com/BenMcLean/cloudydoom) - the same idea for
  Doom: browser play against your own self-hosted server.
