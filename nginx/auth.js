// Custom Basic Auth: any username is accepted, but its password must match
// the single shared PASSWORD (env var, passed through by nginx.conf's
// "env PASSWORD;" and read here via process.env). The username itself
// isn't checked against anything - it's only used as the in-game player
// name (see /config.json's "playerName", consumed by site/app.js's "+name"
// startup arg).
//
// PASSWORD is also the QuakeWorld server's own join password (see
// fteqw-server/docker-entrypoint.sh) - HTTP Basic Auth can't reach the
// WebSocket handshake at all (browsers give JS no way to attach an
// Authorization header to one), so the same secret is handed back to the
// already-authenticated browser in /config.json instead, for app.js to
// stuff as "+password" once it connects. See the README's "How auth
// actually gates the game" section.
//
// PASSWORD is optional - leave it unset/blank only for a deliberately
// public/unlisted server with nothing to gate. As long as USE_LOGIN_NAME
// isn't "false", the login prompt still appears either way, since it's
// also how a player picks their in-game name, but any password (including
// none) is accepted once PASSWORD itself is blank.
//
// If PASSWORD is blank AND USE_LOGIN_NAME is "false", there's nothing left
// for the prompt to gate or collect, so auth is skipped entirely - players
// go straight into the game with fteqw's own default player name.
//
// Auth is applied per-location by js_content, since it needs to run before
// static files, /paks/, and the dynamic /config.json are served - see
// nginx.conf.

var MAX_PLAYER_NAME = 31; // net.h's MAXCLIENTUSERINFO-adjacent name limits are generous; this is a sane display cap, not an engine one.

function useLoginName() {
    return (process.env.USE_LOGIN_NAME || '').toLowerCase() !== 'false';
}

function authRequired() {
    return !!process.env.PASSWORD || useLoginName();
}

function credentials(r) {
    var header = r.headersIn.Authorization;
    if (!header || header.indexOf('Basic ') !== 0) {
        return null;
    }

    var decoded;
    try {
        decoded = Buffer.from(header.slice(6), 'base64').toString();
    } catch (e) {
        return null;
    }

    var sep = decoded.indexOf(':');
    if (sep < 0) {
        return null;
    }

    var user = decoded.slice(0, sep).replace(/[\x00-\x1f\x7f]/g, '').slice(0, MAX_PLAYER_NAME);
    var pass = decoded.slice(sep + 1);

    return { user: user, pass: pass };
}

function isBlank(s) {
    return /^\s*$/.test(s);
}

// Returns { playerName } on success (playerName is null when USE_LOGIN_NAME
// is "false", or when the entered username was blank/whitespace-only - in
// both cases the caller falls back to fteqw's own default player name), or
// null if the request should be rejected.
function authenticate(r) {
    if (!authRequired()) {
        return { playerName: null };
    }

    var creds = credentials(r);
    if (!creds) {
        return null;
    }

    var required = process.env.PASSWORD;
    if (required && creds.pass !== required) {
        return null;
    }

    var playerName = useLoginName() && !isBlank(creds.user) ? creds.user : null;
    return { playerName: playerName };
}

var PAK_ROOT = '/paks';
var PAK_EXT_RE = /\.(pak|pk3)$/i;

// Lists the .pak/.pk3 files directly inside /paks/<gamedir>/, mapping each
// to a {"<gamedir>/<file>": "paks/<gamedir>/<file>"} entry for
// Module.files - see site/app.js. Only top-level files are considered;
// loose (unpacked) assets in a gamedir aren't served to the browser
// client, since retail/mod content is expected to ship as
// pak0.pak/pak1.pak/etc, matching what fteqw-server itself needs anyway
// (see its docker-entrypoint.sh). A missing gamedir (e.g. GAMEDIR unset,
// or pointing at a folder that isn't actually in PAK_DIR) just yields no
// files rather than an error - config() still returns successfully with
// whatever it did find.
function listGameFiles(gamedir) {
    var fs = require('fs');
    var dir = PAK_ROOT + '/' + gamedir;
    var out = {};
    var entries;
    try {
        entries = fs.readdirSync(dir);
    } catch (e) {
        return out;
    }
    for (var i = 0; i < entries.length; i++) {
        var name = entries[i];
        if (!PAK_EXT_RE.test(name)) continue;
        out[gamedir + '/' + name] = 'paks/' + gamedir + '/' + name;
    }
    return out;
}

function unauthorized(r) {
    r.headersOut['WWW-Authenticate'] = 'Basic realm="cloudyquake"';
    r.return(401, 'Authorization required\n');
}

// location / - static site assets.
function serve(r) {
    if (!authenticate(r)) {
        unauthorized(r);
        return;
    }
    r.internalRedirect('@content');
}

// location /paks/ - pak0.pak/pak1.pak/etc. on the mounted volume.
function servePaks(r) {
    if (!authenticate(r)) {
        unauthorized(r);
        return;
    }
    r.internalRedirect('@paks');
}

// location = /config.json - regenerated per-request so it can embed the
// requesting client's own player name. The rest of the fields come from
// config.base.json, written once at container start by docker-entrypoint.sh
// (see CONFIG_BASE_PATH there) from the same env vars as before.
function config(r) {
    var auth = authenticate(r);
    if (!auth) {
        unauthorized(r);
        return;
    }

    var fs = require('fs');
    var base;
    try {
        base = JSON.parse(fs.readFileSync('/etc/cloudyquake/config.base.json'));
    } catch (e) {
        r.return(500, 'config.base.json missing or invalid: ' + e.message + '\n');
        return;
    }
    if (auth.playerName) {
        base.playerName = auth.playerName;
    }
    // The QuakeWorld join password, handed to this already-authenticated
    // client so app.js can stuff it as "+password" - see the file-level
    // comment above for why this can't just ride along on the WebSocket
    // handshake itself.
    base.password = process.env.PASSWORD || '';

    // id1/ is always served; GAMEDIR (same var fteqw-server reads, see its
    // docker-entrypoint.sh) optionally adds a mission pack or mod's own
    // pak files on top, matching the extra "-game" it stacks server-side.
    // Discovered fresh per-request (cheap - a couple of readdirSync calls
    // on a handful of gamedirs) rather than once at container start, so a
    // pak dropped into a running server's volume shows up without a
    // restart.
    var gamedir = process.env.GAMEDIR || '';
    var gameFiles = listGameFiles('id1');
    if (gamedir) {
        var extra = listGameFiles(gamedir);
        for (var key in extra) {
            gameFiles[key] = extra[key];
        }
    }
    base.gameFiles = gameFiles;
    base.gamedir = gamedir || null;

    r.headersOut['Content-Type'] = 'application/json';
    r.headersOut['Cache-Control'] = 'no-store';
    r.return(200, JSON.stringify(base));
}

export default { serve, servePaks, config };
