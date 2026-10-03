// Service worker that keeps the game files (/paks/...) in the browser's
// Cache Storage, so reloading the page or coming back later doesn't
// re-download them. The browser's ordinary HTTP cache isn't reliable for
// this: the files are large (Quake III's pak0 is hundreds of MB, past what
// many browsers will keep in the HTTP cache), come from behind Basic Auth,
// and carry no explicit caching headers.
//
// Cached files are revalidated on each load with a conditional request
// (If-None-Match/If-Modified-Since from the stored response): an unchanged
// file costs a tiny 304, a replaced pak is downloaded again. If the server
// can't be reached, the cached copy is used.

const CACHE = "cloudyquake-paks-v1";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
    const req = e.request;
    const url = new URL(req.url);
    // Range requests and anything outside /paks/ go straight to the network.
    if (req.method !== "GET" || url.origin !== location.origin || !url.pathname.startsWith("/paks/") || req.headers.has("range")) return;
    e.respondWith(pak(e));
});

async function pak(e) {
    const req = e.request;
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req.url);
    if (!cached) return fetchAndStore(e, cache);

    const headers = new Headers();
    const etag = cached.headers.get("ETag");
    const modified = cached.headers.get("Last-Modified");
    if (etag) headers.set("If-None-Match", etag);
    if (modified) headers.set("If-Modified-Since", modified);
    // Nothing to validate against: trust the cached copy.
    if (!etag && !modified) return cached;

    let res;
    try {
        res = await fetch(req.url, { headers, credentials: "same-origin" });
    } catch (err) {
        return cached; // offline or server down
    }
    if (res.status === 304) return cached;
    if (res.ok) return store(e, cache, res);
    // 401 (password changed) and the like: don't serve or keep stale data.
    if (res.status === 401 || res.status === 403 || res.status === 404) await cache.delete(req.url);
    return res;
}

async function fetchAndStore(e, cache) {
    const res = await fetch(e.request);
    return res.status === 200 ? store(e, cache, res) : res;
}

// Streams the response to the page and into the cache at the same time,
// rather than waiting for the whole file to be cached first. A failed write
// (e.g. storage quota exceeded) just means no caching, not a failed download.
function store(e, cache, res) {
    e.waitUntil(
        cache.put(e.request.url, res.clone()).catch((err) => {
            console.warn("cloudyquake: could not cache " + e.request.url, err);
        })
    );
    return res;
}
