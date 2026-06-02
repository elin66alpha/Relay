// AgentDeck push-only service worker.
//
// This worker exists solely to receive Web Push messages and show notifications
// when the AgentDeck tab is closed. It deliberately does NOT cache anything (no
// `fetch`/`install` caching), so it can never serve a stale app shell — the app
// is always loaded fresh from the network. The page's cleanup script preserves
// this worker by name while still removing any old Flutter PWA worker.

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_e) {
    data = {};
  }
  const title = data.title || 'AgentDeck';
  const body = data.body || '';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: body,
      tag: data.tag || 'agentdeck',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      data: data,
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      });
      for (const client of all) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('./');
    })(),
  );
});
