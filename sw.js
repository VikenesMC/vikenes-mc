// Service worker for medlemssida: viser push-varsel frå chatten.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Vikenes MC", {
    body: d.body || "",
    icon: "logo.png",
    badge: "logo.png",
    tag: d.tag || "chat",
    renotify: true,
    data: { url: d.url || "medlem.html" },
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "medlem.html", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((liste) => {
    for (const c of liste) {
      if (c.url.includes("medlem.html")) { c.postMessage("opne-chat"); return c.focus(); }
    }
    return self.clients.openWindow(url);
  }));
});
