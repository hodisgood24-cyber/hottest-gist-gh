// Hottest Gist GH service worker: makes the site installable, shows an offline note, and receives phone notifications.
const CACHE = "hg-v1";
self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(["/offline.html", "/icon-192.png"])).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
// Always use the live site; only show the offline page when there is no connection.
self.addEventListener("fetch", (e) => {
  if (e.request.mode !== "navigate") return;
  e.respondWith(fetch(e.request).catch(() => caches.match("/offline.html")));
});
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: e.data && e.data.text() }; }
  const title = d.title || "Hottest Gist GH";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
    // Message alerts are skipped when the site is already open on screen.
    if (d.dm && cs.some((c) => c.visibilityState === "visible")) return;
    return self.registration.showNotification(title, {
    body: d.body || "New gist just dropped 🔥",
    icon: "/icon-192.png",
    badge: "/favicon-48.png",
    image: d.image || undefined,
    tag: d.tag || "gist",
    requireInteraction: !!d.ring,
    renotify: !!d.ring,
    vibrate: d.ring ? [300, 150, 300, 150, 300] : undefined,
    data: { url: d.url || "/" }
  });
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "/";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
    for (const c of cs) { if ("focus" in c) { c.navigate(url); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
