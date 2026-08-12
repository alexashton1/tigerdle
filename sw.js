// Deliberately minimal, this exists purely so Chrome/Android recognizes
// the site as installable. It does NOT cache anything or serve content
// offline, so there's no risk of someone seeing a stale version of the
// site, stale scores, or a stale prediction lock time. Every request
// still goes straight to the network, exactly as if this file didn't
// exist at all, it only needs to be present and registered.

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
