// Offline support for the driver portal (and any web build from web/).
//
// Flutter's own flutter_service_worker.js is deprecated and now only
// unregisters itself, so this replaces it (see web/flutter_bootstrap.js,
// which stops Flutter registering its own). Registered from index.html.
//
// - On install it pre-caches the app shell. tool/build_driver_web.dart
//   fills in PRECACHE with every file the build produced; a build made
//   without that script leaves it empty, and the app still becomes
//   available offline from the second visit through runtime caching.
// - App files: network first (so a new deploy shows up as soon as you're
//   online), falling back to the cached copy offline.
// - Fonts and Firebase's JS from Google's CDNs: cache first.
// - Firestore / Auth traffic is never touched: Firestore keeps its own
//   offline copy of the data (persistence is on in lib/main_driver.dart).

const VERSION = '__VERSION__';
const PRECACHE = /*__PRECACHE__*/[];
const CACHE = `paypark-${VERSION}`;

const CDN_HOSTS = [
  'www.gstatic.com',
  'fonts.gstatic.com',
  'fonts.googleapis.com',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      // One by one so a single missing file doesn't sink the whole install.
      await Promise.all(
        ['./', ...PRECACHE].map((url) =>
          cache.add(new Request(url, { cache: 'reload' })).catch((e) =>
            console.warn('[offline_sw] precache skipped', url, e))));
      await self.skipWaiting();
    })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key.startsWith('paypark-') && key !== CACHE) {
          await caches.delete(key);
        }
      }
      await self.clients.claim();
    })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    event.respondWith(networkFirst(req));
  } else if (CDN_HOSTS.includes(url.hostname)) {
    event.respondWith(cacheFirst(req));
  }
  // Everything else (Firestore, Auth, …) goes straight to the network.
});

async function networkFirst(req) {
  const cache = await caches.open(CACHE);
  try {
    const res = await fetch(req);
    if (res.ok) cache.put(req, res.clone());
    return res;
  } catch (e) {
    const hit = await cache.match(req, { ignoreSearch: true });
    if (hit) return hit;
    // A deep link (e.g. /history) opened offline: serve the app shell.
    if (req.mode === 'navigate') {
      const shell = await cache.match('./');
      if (shell) return shell;
    }
    throw e;
  }
}

async function cacheFirst(req) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  // Opaque (no-cors) responses are fine to keep for fonts/scripts.
  if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
  return res;
}
