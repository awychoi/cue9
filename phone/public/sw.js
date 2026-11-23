/** cue9 phone service worker: app shell cache and Web Push (when enabled). */
const CACHE = 'cue9-phone-v6'
const SHELL = ['/', '/app.js', '/styles.css', '/manifest.webmanifest', '/icon.svg', '/icon-192.png']

/** Only same-origin destinations are opened; a pushed URL is not trusted. */
function safeUrl(value) {
  if (typeof value !== 'string' || value.length === 0) return '/'
  try {
    const url = new URL(value, self.location.origin)
    if (url.origin !== self.location.origin) return '/'
    return `${url.pathname}${url.search}${url.hash}`
  } catch {
    return '/'
  }
}

self.addEventListener('install', event => {
  self.skipWaiting()
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).catch(() => {}))
})

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys()
    await Promise.all(names.filter(name => name !== CACHE).map(name => caches.delete(name)))
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', event => {
  const request = event.request
  if (request.method !== 'GET') return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return
  if (url.pathname.startsWith('/api/')) return
  event.respondWith((async () => {
    try {
      const response = await fetch(request)
      if (response.ok) {
        const cache = await caches.open(CACHE)
        void cache.put(request, response.clone())
      }
      return response
    } catch {
      return (await caches.match(request)) ?? (await caches.match('/')) ?? Response.error()
    }
  })())
})

self.addEventListener('push', event => {
  let payload = {}
  try { payload = event.data?.json() ?? {} } catch { payload = {} }
  const title = typeof payload.title === 'string' ? payload.title : 'cue9 needs you'
  const body = typeof payload.body === 'string' ? payload.body : 'Open cue9 to review.'
  const url = safeUrl(typeof payload.url === 'string' ? payload.url : payload.data?.url)
  const tag = typeof payload.tag === 'string' ? payload.tag : 'cue9'

  event.waitUntil((async () => {
    try {
      await self.registration.showNotification(title, {
        body,
        tag,
        renotify: true,
        data: { url },
        icon: '/icon-192.png',
        badge: '/icon-192.png',
      })
    } catch { /* the in-app confirmation still runs */ }

    try { await self.navigator?.setAppBadge?.(1) } catch { /* Badging API may be unavailable */ }

    try {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      for (const client of windows) {
        try { client.postMessage({ type: 'cue9-push', title, body, url, tag }) } catch { /* one client closed */ }
      }
    } catch { /* no open windows */ }
  })())
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  const url = safeUrl(event.notification.data?.url)
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const client of all) {
      if ('focus' in client) {
        if ('navigate' in client) {
          try { await client.navigate(url) } catch { /* keep the current page */ }
        }
        await client.focus()
        return
      }
    }
    await self.clients.openWindow(url)
  })())
})
