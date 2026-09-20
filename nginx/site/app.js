// Loader for ftewebgl.js (fteqw's Emscripten/web port).
//
// Unlike fteqw's own default engine/web/fteshell.html, this never shows the
// drag-and-drop "bring your own files" prompt - config.json (generated at
// container start from environment variables, plus the requesting client's
// own Basic Auth credentials - see nginx/auth.js) already has everything
// needed to connect automatically: which pak files to preload, which
// server to +connect to, and (once logged in) the player's name and the
// server's join password. Nothing here is baked in at image build time.
//
// ftewebgl.js itself is loaded dynamically, *after* config.json resolves
// and Module is fully populated - not via a static <script> tag in
// index.html - because fteqw reads Module.arguments/Module.files at
// startup, before any of our own code would otherwise get a chance to set
// them. This mirrors what engine/web/fteshell.html's own begin() function
// does, just skipping the file-drop UI entirely. See fteqw's
// specs/hosting.txt for the Module.arguments/Module.files contract.

const statusEl = document.getElementById("status");

function setStatusText(text) {
    if (text === undefined) return;
    statusEl.textContent = text === null ? "" : text;
}

var Module = {
    canvas: (function () {
        var canvas = document.getElementById("canvas");
        canvas.addEventListener(
            "webglcontextlost",
            function (e) {
                alert("WebGL context lost. You will need to reload the page.");
                e.preventDefault();
            },
            false
        );
        return canvas;
    })(),
    files: {}, // populated below once config.json resolves
    print: function (msg) {
        console.log(msg);
    },
    printErr: function (text) {
        console.error(text);
    },
    setStatus: function (text) {
        // gets spammed some prints during startup, same as fteshell.html.
        if (Module.setStatus.interval) clearInterval(Module.setStatus.interval);
        var m = text.match(/([^(]+)\((\d+(\.\d+)?)\/(\d+)\)/);
        if (m) {
            setStatusText(m[1] + "(" + Math.round(m[2]) + "/" + Math.round(m[4]) + ")");
        } else {
            setStatusText(text);
        }
    },
    totalDependencies: 0,
    monitorRunDependencies: function (left) {
        this.totalDependencies = Math.max(this.totalDependencies, left);
        Module.setStatus(left ? "Preparing... (" + (this.totalDependencies - left) + "/" + this.totalDependencies + ")" : "All downloads complete.");
    },
    postRun: [
        function () {
            if (Module["sched"] === undefined) {
                alert("Unable to initialise. You may need to restart your browser. If you get this often and inconsistently, consider using a 64bit browser instead.");
                Module.setStatus("Initialisation Failure");
            }
        },
    ],
};

window.onerror = function () {
    Module.setStatus("Exception thrown, see JavaScript console");
    Module.setStatus = function (text) {
        if (text) Module.printErr("[post-exception status] " + text);
    };
};

function loadEngine() {
    var s = document.createElement("script");
    s.setAttribute("src", "ftewebgl.js");
    s.setAttribute("type", "text/javascript");
    s.setAttribute("charset", "utf-8");
    s.addEventListener(
        "error",
        function () {
            setStatusText("Unable to download engine javascript");
        },
        false
    );
    document.head.appendChild(s);
}

fetch("config.json", { cache: "no-store" })
    .then((r) => {
        if (!r.ok) throw new Error(`config.json: HTTP ${r.status}`);
        return r.json();
    })
    .then((config) => {
        if (!config.wsUrl) throw new Error("config.json is missing wsUrl");
        if (!config.gameFiles || !Object.keys(config.gameFiles).length) {
            throw new Error("config.json has no gameFiles - is a pak0.pak actually in the " + (config.baseGamedir || "id1") + "/ folder of your PAK_DIR volume?");
        }

        // String values in Module.files are treated as URLs and downloaded
        // before any C code runs - see fteqw's engine/web/fteshell.html.
        // config.gameFiles's keys are already fteqw's own expected virtual
        // paths (e.g. "id1/pak0.pak", "hipnotic/pak0.pak") - see
        // nginx/auth.js's listGameFiles().
        for (const [virtualPath, url] of Object.entries(config.gameFiles)) {
            Module.files[virtualPath] = url;
        }

        // config.playerName/config.password are only present once the
        // player has authenticated - see nginx/auth.js's config(). Both
        // are simply omitted (rather than sent empty) when there's
        // nothing to set, so fteqw falls back to its own defaults.
        //
        // "+set name X"/"+set password X", not bare "+name X"/"+password
        // X" - matches nginx/docker-entrypoint.sh's own nativeClientCmd
        // convenience string (see its PASSWORD_ARG), which has always used
        // the explicit "+set" form. The bare form relies on fteqw falling
        // an unrecognised startup command through to a same-named cvar,
        // which turned out not to reliably apply before Quake II's own
        // connect handshake reads it (surfaced as new players landing as
        // "unnamed" under GAME=quake2) - "+set" goes through the real,
        // always-registered "set" command instead, sidestepping that
        // fallback entirely.
        const nameArgs = config.playerName ? ["+set", "name", config.playerName] : [];
        const passArgs = config.password ? ["+set", "password", config.password] : [];
        // config.gamedirs mirrors fteqw-server's own extra "-game GAMEDIRS"
        // stack (see its docker-entrypoint.sh), in the same order - a
        // mission pack/mod/map pack's client-visible assets need this to
        // actually get searched, same as the server needs it for its own
        // gamecode/assets.
        const gameArgs = Array.isArray(config.gamedirs) ? config.gamedirs.flatMap((gd) => ["-game", gd]) : [];

        // config.clientArgs (CLIENT_ARGS) is a raw fteqw command-line
        // passthrough - see .env.example. If your server's SERVER_ARGS
        // includes an engine-mode switch like "-hexen2", add the same
        // switch to CLIENT_ARGS here too, same as a native client would
        // need it. "-"-prefixed switches are parsed by fteqw up front
        // regardless of where they fall in argv (unlike "+" commands,
        // which run in the order given), so clientArgs's own position
        // relative to +connect doesn't matter for those - nameArgs/passArgs
        // are placed before +connect anyway, on general principle (set
        // userinfo before connecting, not after).
        Module.arguments = gameArgs
            .concat(Array.isArray(config.clientArgs) ? config.clientArgs : [])
            .concat(nameArgs)
            .concat(passArgs)
            .concat(["+connect", config.wsUrl]);

        setStatusText("Downloading game data...");
        loadEngine();
    })
    .catch((err) => {
        console.error(err);
        setStatusText("Failed to load configuration: " + err.message);
    });
