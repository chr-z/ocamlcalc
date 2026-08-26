/* OCamlCalc service worker — offline-first.
 * __OC_CACHE_VERSION__ is replaced by CI with the deploy SHA so every
 * deploy ships a fresh cache. Locally it falls back to a dev stamp. */
var CACHE_VERSION = '__OC_CACHE_VERSION__';
if (CACHE_VERSION.indexOf('__') === 0) CACHE_VERSION = 'oc-dev';

var CORE = [
  './',
  './index.html',
  './css/style.css',
  './js/i18n.js',
  './js/app.js',
  './js/ui.js',
  './locales/i18n.json',
  './manifest.json',
  './assets/icons/icon.svg'
];

self.addEventListener('install', function (evt) {
  evt.waitUntil(
    caches.open(CACHE_VERSION)
      .then(function (c) { return c.addAll(CORE); })
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (evt) {
  evt.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) {
        if (k !== CACHE_VERSION) return caches.delete(k);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (evt) {
  var req = evt.request;
  if (req.method !== 'GET') return;
  evt.respondWith(
    caches.match(req).then(function (hit) {
      if (hit) return hit;
      return fetch(req).then(function (res) {
        var copy = res.clone();
        caches.open(CACHE_VERSION).then(function (c) { c.put(req, copy); }).catch(function () {});
        return res;
      }).catch(function () {
        if (req.mode === 'navigate') return caches.match('./index.html');
      });
    })
  );
});
