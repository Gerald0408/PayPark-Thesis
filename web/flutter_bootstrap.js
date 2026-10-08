{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: Flutter's own service worker is deprecated and
// only unregisters itself — which would also remove web/offline_sw.js,
// since both live at the site root. Offline caching is offline_sw.js's job
// (registered in index.html).
_flutter.loader.load();
