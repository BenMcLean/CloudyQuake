# CloudyQuake

Multiplayer QuakeW, playable straight in the browser and
hosted on your own dedicated server. Supports Quake 1, 2 and 3.
For the people you invite to play: no client install, no router config, just a URL and a password.
Everything here is open source and runs as a docker-compose stack.

The "no setup" experience is only true for players - **you, running the
server, still need to expose it to the internet**, same as hosting any other
self-hosted service. [Deploying](#deploying) lists every hostname and port
involved in one place.

Native clients (fteqw, or any other compatible engine) can also
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

Everything runs in **one container**, built in the style of the
[linuxserver.io](https://www.linuxserver.io/) images: an Ubuntu base with
[s6-overlay](https://github.com/just-containers/s6-overlay) supervising three
services, `PUID`/`PGID`/`TZ` support, and a `/config` volume.

| Service (s6) | What it is |
|---|---|
| `svc-nginx` | Serves the web client (fteqw's own Emscripten/WebGL port, built from [`fte-team/fteqw`](https://github.com/fte-team/fteqw) at build time - see `FTEQW_REF`) behind HTTP Basic Auth. Also serves your pak files, so the auth gate covers those too. |
| `svc-fteqw-server` | A real, unmodified fteqw dedicated server (built from the same pinned `FTEQW_REF`), running standard QuakeWorld gamecode compiled from fteqw's own openly-licensed `quakec/basemod`. Serves WebRTC, WebSocket and native UDP clients. |
| `svc-ftemaster` | The WebRTC/ICE broker (fteqw's own `ftemaster` binary). Only relays the handshake that lets browsers and `fteqw-server` find each other. Only runs when `NET_ICE_BROKER` is set. |

A one-shot `init-cloudyquake-config` runs first: it validates settings,
symlinks your gamedirs into fteqw's basedir and generates the web client's
`config.json` base. Mounts: `/paks` (your game data, read-only is fine) and
`/config` (fteqw's own config and logs).

Ports and hostnames are all in [Deploying](#deploying).

## Supported games

The same image supports every game. `GAME` (default `qw`) is a plain runtime
environment variable that picks which engine-mode flag `svc-fteqw-server`
forces on at startup; the gamecode for all supported games is already baked
into the image (see the `Dockerfile`), so switching games is a restart, not
a rebuild.

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
unset) - gamecode compiled from fteqw's
own openly-licensed `quakec/basemod` into the image at
build time (see [Why fteqw-server needs your paks too](#why-fteqw-server-needs-your-paks-too)).
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
fixed release tag in the `Dockerfile`): unlike QuakeWorld/Hexen
II's QuakeC, Quake II's gamecode is a natively-compiled shared library
that fteqw `dlopen()`s at runtime rather than
bundling itself, so the image's build compiles one from yquake2's `src/game/` -
just the gamecode, not its client/server/renderer, which this project has
no use for - and bakes it into the image the same general
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

`GAME=quake3`, `BASE_GAMEDIR=baseq3`, with `baseq3/pak0.pk3` (and the other
`pak*.pk3` files from a retail install) in your `PAK_DIR`. fteqw's Quake III
support (including its bot library) is already part of the stock engine and
the browser client, so nothing extra is built. The game's QVMs come from your
own pk3s. Browsers download every pk3 in `baseq3/`, which is about 500MB for
a retail install, so the first load is slow. Don't copy your install's `q3key`
file into `PAK_DIR`.

## Quick start

You do **not** need to clone this repo or build anything: a prebuilt image is
published to the GitHub Container Registry. This works the same on Windows,
macOS and Linux, and takes about five minutes if you already own the game.

**1. Install Docker.** On Windows or macOS, install
[Docker Desktop](https://www.docker.com/products/docker-desktop/) and start
it. On Linux, install Docker Engine with the Compose plugin. Check that
`docker compose version` prints a version.

**2. Make a folder and put your game files in it.** CloudyQuake never ships
the game itself, so you need your own copy (the GOG, Steam or retail install
will do). For Quake, make a folder called `cloudyquake` with a `paks/id1/`
folder inside it, and copy your `pak0.pak` (and `pak1.pak`, for the full game)
into that:

```
cloudyquake/
  docker-compose.yml     <- you create this in step 3
  paks/
    id1/
      pak0.pak
      pak1.pak
```

The file names must be lowercase on Linux. For other games see
[Getting paks](#getting-paks) and the table after the example below.

**3. Create `docker-compose.yml`** in the `cloudyquake` folder with the text
below. This is the "one with everything" example: every setting is listed
with a comment, set up for WebRTC, the recommended way to play. Replace
`example.com` with your own domain (the names are explained in
[Hostnames](#hostnames)), and change `PASSWORD`.

```yaml
services:
  cloudyquake:
    image: ghcr.io/benmclean/cloudyquake:latest
    container_name: cloudyquake
    restart: unless-stopped
    environment:
      # --- Who the container runs as. 1000/1000 is right for Docker Desktop.
      # On Linux, set these to the owner of your paks folder (run `id`).
      PUID: "1000"
      PGID: "1000"
      TZ: Etc/UTC

      # --- Login. Everyone uses this one password. Any username works, and
      # the username they type becomes their in-game name. Leave PASSWORD
      # empty and set USE_LOGIN_NAME to "false" for no login at all.
      PASSWORD: changeme
      USE_LOGIN_NAME: "true"

      # --- How browsers connect to the game server. Pick ONE.
      #
      # Option A (used here, recommended): WebRTC. Game traffic travels over
      # UDP, so a lost packet only costs that one packet. NET_ICE_BROKER is
      # the public address of the broker that introduces browsers to the
      # server (through your TLS reverse proxy). Setting it turns WebRTC on.
      NET_ICE_BROKER: wss://quakebroker.example.com/
      # The server's own hostname. Must resolve to this machine's UDP port
      # 27500. It is only used to build the command shown to people who play
      # with a native Quake client instead of the browser.
      SV_HOST: quakeserver.example.com
      # Option B: WebSocket only, which works on any network but runs over
      # TCP. To use it, leave NET_ICE_BROKER empty ("") and set:
      #   WS_URL: wss://quakeserver.example.com
      WS_URL: ""
      # Advanced WebRTC settings. The defaults are fine.
      NET_ICE_NAME: /cloudyquake
      FTEMASTER_PORT: "27950"
      FTEMASTER_HOST: ""

      # --- Which game to run. "qw" (Quake, the default), "quake2" or
      # "quake3". BASE_GAMEDIR is the folder inside ./paks that holds the
      # base game: id1 for Quake, baseq2 for Quake II, baseq3 for Quake III.
      GAME: qw
      BASE_GAMEDIR: id1
      # Extra folders in ./paks to stack on top: mission packs, mods, map
      # packs. Space-separated, e.g. "hipnotic" or "rogue xatrix".
      GAMEDIRS: ""

      # --- Game server settings, passed straight to the Quake server. This
      # example hosts a 16-player deathmatch on the map dm3. The
      # net_ice_servers part names a STUN server, which WebRTC needs so both
      # sides can learn their public address. It does nothing in WebSocket
      # mode, so it is safe to leave in.
      SERVER_ARGS: "+set hostname CloudyQuake +set deathmatch 1 -dedicated 16 +set sv_public 0 +set net_ice_servers stun:stun.l.google.com:19302 +map dm3"
      # Extra options for each player's browser. The STUN server must match
      # the one in SERVER_ARGS. Add more, e.g. "+set scr_conscale 4" for a
      # bigger on-screen display.
      CLIENT_ARGS: "+set net_ice_servers stun:stun.l.google.com:19302"

      # --- Ports inside the container. If you change these, change the
      # matching numbers in "ports" below too.
      SV_PORT: "27500"
      SV_PORT_TCP: "27500"
    ports:
      - "27501:8080"        # the web page: http://localhost:27501
      - "27500:27500/tcp"   # game server, WebSocket
      - "27500:27500/udp"   # game server, WebRTC and native Quake clients
      - "27950:27950/tcp"   # WebRTC broker (only used with NET_ICE_BROKER)
      - "27950:27950/udp"
    volumes:
      - ./config:/config
      - ./paks:/paks:ro
```

**4. Start it.** In a terminal, inside the `cloudyquake` folder:

```
docker compose up -d
```

The first run downloads the image, which takes a minute or two.

**5. Play.** Open your site's address (`https://quake.example.com` once the
setup below is done) in your browser, log in with any username and the
password from the file (`changeme` above), and you are in. The first load
downloads the game files to your browser, so it takes a while for Quake II and
Quake III.

For this to work from the internet you also need three things outside this
file, all covered in [Deploying](#deploying): DNS names for the three
hostnames in the example, a TLS reverse proxy in front of the web page and the
broker (browsers refuse to talk to plain `ws://` from an `https://` page), and
UDP port `27500` forwarded from your router to this machine.

To try it on your own computer first, with no domain or proxy, set
`NET_ICE_BROKER: ws://localhost:27950/` and open <http://localhost:27501>. See
[Testing WebRTC locally in Docker Desktop](#testing-webrtc-locally-in-docker-desktop)
for the one browser setting that needs.

Everyday commands, run in the same folder:

```
docker compose logs -f           # watch the server log (Ctrl+C to stop watching)
docker compose down              # stop and remove the container
docker compose pull              # fetch a newer image...
docker compose up -d             # ...then restart on it
```

**Other games.** Change `GAME`, `BASE_GAMEDIR` and the map in `SERVER_ARGS`,
put the matching game files in that folder under `paks/`, then run
`docker compose up -d` again (no rebuild is needed):

| Game | `GAME` | `BASE_GAMEDIR` | Game files go in | Example map in `SERVER_ARGS` |
|---|---|---|---|---|
| Quake | `qw` | `id1` | `paks/id1/` (`pak0.pak`, `pak1.pak`) | `+map dm3` |
| Quake II | `quake2` | `baseq2` | `paks/baseq2/` (`pak0.pak`, ...) | `+map q2dm1` |
| Quake III Arena | `quake3` | `baseq3` | `paks/baseq3/` (`pak0.pk3`, ...) | `+map q3dm1` |

Quake III support is **experimental**: the match starts and plays, but in
testing the browser lost its connection after one to two minutes, over both
WebRTC and WebSocket.

**Building it yourself instead** (to change the code): clone this repo, copy
`.env.example` to `.env`, edit it, and run `docker compose up -d --build`.
The `docker-compose.yml` in the repo does exactly that.

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
[Why fteqw-server needs your paks too](#why-fteqw-server-needs-your-paks-too) -
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

`PAK_DIR` is mounted **read-only** at `/paks` - nothing in the container can
write to it. The services run as `PUID`/`PGID` (default `1000`/`1000`, as in
other linuxserver.io images), which must be able to *read* whatever's in that
directory. If you hit a permission error here, set `PUID`/`PGID` in `.env` to
match that directory's actual owner - see `.env.example`.

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
  WebSocket to WebRTC.** `fteqw-server` itself always talks to the `ftemaster`
  running in the same container, so there's no matching setting for that
  side (`FTEMASTER_HOST` overrides the address it uses, if you need to).
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
  server (which reaches `ftemaster` over the container's own address) would
  learn a private address instead of your public one. Any public STUN server works;
  use your own if you'd rather not depend on Google's.

All of these are read once and used by `fteqw-server`, `ftemaster`, *and*
`nginx` (for the browser client) - see `docker-compose.yml`.

**Check it.** Add `+set net_ice_debug 2` to `SERVER_ARGS`/`CLIENT_ARGS`, load
the site, and look at `docker compose logs cloudyquake`: you should see
`Publicly listening on /myserver`, the browser's candidates, your public IP as
the server's `Public address`, and finally `ice state connected`. If it stays
on "Waiting for broker connection" the broker Proxy Host (or its Websockets
toggle) is the problem; if it reaches `connecting` but times out, UDP `27500`
isn't reaching the server.

If a player's network blocks UDP, WebRTC can't work for them and there is no
automatic fallback. Instead, set `WS_URL` as well (see the WebSocket
alternative below) and have them add `?ws` to the page address, e.g.
`https://quake.example.com/?ws`. That makes their browser connect over
WebSocket while everyone else keeps using WebRTC. `?ws` is ignored if
`WS_URL` isn't set.

### Alternative: WebSocket only

Simpler, works on any network, but subject to the TCP stalls described
above. Leave `NET_ICE_BROKER` blank, and set:

```
WS_URL=wss://quakeserver.example.com
```

You then don't need the `quakebroker` hostname, its Proxy Host, or the broker
port (`ftemaster` isn't started at all). The UDP `27500`
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
  candidate and connectivity check in `docker compose logs cloudyquake`
  and the browser console.

## Troubleshooting

- **Browser client connects then immediately gets kicked/rejected**: check
  `PASSWORD` matches between `.env`'s single shared value and what you typed
  at the login prompt - `nginx/auth.js` hands the same secret to the
  already-authenticated browser via `/config.json` for it to send as
  `+password`, so a mismatch here usually means stale `.env` values from
  before a `docker compose up` that didn't recreate the container.
- **Connection fails only through the reverse proxy, works fine hitting the
  container's port directly**: almost always the "Websockets Support" toggle
  in nginx-proxy-manager (or the equivalent `proxy_set_header
  Upgrade`/`Connection` directives in a hand-written nginx config) on the
  broker or game-server host - see [Reverse proxy](#reverse-proxy-nginx-proxy-manager).
- **WebRTC connect fails/times out**: check, in order:
  1. `docker compose logs cloudyquake` should show `Publicly listening on
     /<name>`. If it doesn't, the server never registered with the broker
     (see the `tcp://`/trailing-slash note above).
  2. Set `net_ice_debug 2` and look at the candidates the server logs. If
     the browser only offers `.local` (mDNS) and Docker-gateway addresses,
     it's the local Docker Desktop case above.
  3. The broker's Proxy Host needs "Websockets Support" enabled.
  4. `SV_PORT` (udp) must be forwarded through your router straight to
     `fteqw-server`, and both sides need a reachable STUN server - see
     [Configuring WebRTC](#configuring-webrtc-recommended).

## Why fteqw-server needs your paks too

QuakeWorld is a genuine client-server model: the server is authoritative and
actually runs the game simulation, so `fteqw-server` needs real access to the
map/model/sound data in your paks to do that - not just `nginx`, which only
needs them to hand out to browsers.

`/paks` isn't used directly as fteqw's basedir (`/fte`) - that basedir also
holds a `qw/` folder baked into the image at build time (fteqw's own compiled
QuakeWorld gamecode, see [Credits / license](#credits--license)), and a bind
mount would hide that entirely rather than merge with it. Instead
`init-cloudyquake-config` symlinks each gamedir subfolder it finds in `/paks`
into `/fte/` at container start - so a `paks/qw/` of your own (e.g. copied
from a full retail install) still takes priority over the built-in one,
instead of silently failing to appear at all.

## Credits / license

- [`fte-team/fteqw`](https://github.com/fte-team/fteqw) - the QuakeWorld
  engine (with an Emscripten/WebGL web port and native WebSocket support
  built in) this is built on, fetched at build time from a pinned tag (see
  `FTEQW_REF` in the `Dockerfile`) rather
  than vendored, since it's used entirely unmodified here.
- The dedicated server's gamecode is compiled from fteqw's own
  `quakec/basemod` - see its `basemod.txt` for license terms. The actual
  game data (maps, models, textures, sounds) always comes from your own pak
  volume, never baked into any image here.

## Other Projects

- [CloudyDoom](https://github.com/BenMcLean/CloudyDoom) - the same idea for
  Doom: browser play against your own self-hosted server.
