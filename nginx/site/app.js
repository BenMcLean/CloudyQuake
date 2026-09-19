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
        if (!config.pak0Url) throw new Error("config.json is missing pak0Url");

        // String values in Module.files are treated as URLs and downloaded
        // before any C code runs - see fteqw's engine/web/fteshell.html.
        // The virtual path (left side) has to be fteqw's own expected
        // location for these files under its default "id1" gamedir.
        Module.files["id1/pak0.pak"] = config.pak0Url;
        if (config.pak1Url) {
            Module.files["id1/pak1.pak"] = config.pak1Url;
        }

        // config.playerName/config.password are only present once the
        // player has authenticated - see nginx/auth.js's config(). Both
        // are simply omitted (rather than sent empty) when there's
        // nothing to set, so fteqw falls back to its own defaults.
        const nameArgs = config.playerName ? ["+name", config.playerName] : [];
        const passArgs = config.password ? ["+password", config.password] : [];

        Module.arguments = ["+connect", config.wsUrl]
            .concat(nameArgs)
            .concat(passArgs)
            .concat(Array.isArray(config.extraArgs) ? config.extraArgs : []);

        setStatusText("Downloading game data...");
        loadEngine();
    })
    .catch((err) => {
        console.error(err);
        setStatusText("Failed to load configuration: " + err.message);
    });
