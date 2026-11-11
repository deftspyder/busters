// Busters service worker: shows phone alerts and opens the right screen when one is tapped.
// It does not cache pages, so the app always loads fresh from GitHub Pages.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: 'Busters', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Busters', {
    body: d.body || '', icon: 'icons/icon-192.png?v=4', tag: d.tag || undefined, data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL((e.notification.data || {}).url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) if (w.url.startsWith(self.registration.scope)) { try { await w.navigate(target); } catch (err) {} return w.focus(); }
    return self.clients.openWindow(target);
  })());
});
