/** The phone-facing HTTPS origin: static PWA, pairing, pending API, answers, SSE. */
import { createServer as createHttpServer } from 'node:http'
import { createServer as createHttpsServer } from 'node:https'
import { readFile } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { MAX_BODY_BYTES } from './validate.js'

const STATIC = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/index.html', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
  ['/sw.js', ['sw.js', 'text/javascript; charset=utf-8']],
  ['/manifest.webmanifest', ['manifest.webmanifest', 'application/manifest+json; charset=utf-8']],
  ['/icon.svg', ['icon.svg', 'image/svg+xml']],
  ['/icon-192.png', ['icon-192.png', 'image/png']],
  ['/icon-512.png', ['icon-512.png', 'image/png']],
  ['/apple-touch-icon.png', ['apple-touch-icon.png', 'image/png']],
  ['/pair', ['pair.html', 'text/html; charset=utf-8']],
  ['/pair.js', ['pair.js', 'text/javascript; charset=utf-8']],
  ['/pair.css', ['pair.css', 'text/css; charset=utf-8']],
])

const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])
const MAX_SSE_CLIENTS = 8
const CONTENT_SECURITY_POLICY = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

function isHttps(req) {
  if (req.socket.encrypted === true) return true
  const forwarded = req.headers['x-forwarded-proto']
  const raw = Array.isArray(forwarded) ? forwarded[0] : forwarded
  const first = String(raw ?? '').split(',')[0].trim().toLowerCase()
  return first === 'https'
}

function setSecurityHeaders(req, res) {
  res.setHeader('Content-Security-Policy', CONTENT_SECURITY_POLICY)
  res.setHeader('X-Content-Type-Options', 'nosniff')
  res.setHeader('X-Frame-Options', 'DENY')
  res.setHeader('Referrer-Policy', 'no-referrer')
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
  if (isHttps(req)) {
    res.setHeader('Strict-Transport-Security', 'max-age=15552000')
  }
}

function sendJson(res, status, value, extra = {}) {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...extra,
  })
  res.end(body)
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new Error('body-too-large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      } catch {
        reject(new Error('invalid-json'))
      }
    })
    req.on('error', reject)
  })
}

function resultStatus(result) {
  if (result === true) return 200
  if (result?.ok === true) return 200
  if (result?.error === 'claim-mismatch') return 409
  if (result?.error === 'not-found') return 404
  if (result?.error === 'invalid-answer') return 400
  return 400
}

function resultError(result) {
  if (result === false) return 'not-found'
  if (typeof result?.error === 'string') return result.error
  return 'failed'
}

/**
 * Create the phone server without binding it.
 * @param {{
 *   config: object,
 *   store: import('./store.js').RequestStore,
 *   sessions: ReturnType<import('./sessions.js').createSessions>,
 *   push?: object,
 *   log?: Function,
 *   audit?: object,
 *   getPush?: () => object | undefined,
 * }} options
 */
export function createPhoneServer({
  config,
  store,
  sessions,
  push,
  log = console.log,
  audit,
  getPush,
}) {
  const clients = new Set()
  const clientDevices = new Map()
  const pairAttempts = new Map()
  let lastSeenAt = 0
  /** Read the live config; setup may add publicOrigin after the server was created. */
  function currentOrigin() {
    return typeof config.publicOrigin === 'string' && config.publicOrigin.length > 0
      ? config.publicOrigin.replace(/\/$/, '')
      : undefined
  }

  function currentHost() {
    const origin = currentOrigin()
    if (origin === undefined) return undefined
    try {
      return new URL(origin).host.toLowerCase()
    } catch {
      return undefined
    }
  }

  const resolvePush = () => (push !== undefined ? push : getPush?.())

  function pairingClientKey(req) {
    const forwarded = req.headers['x-forwarded-for']
    const raw = Array.isArray(forwarded) ? forwarded[0] : forwarded
    const first = String(raw ?? '').split(',')[0].trim()
    return first.length > 0 ? first : String(req.socket.remoteAddress ?? 'unknown')
  }

  function pairingRateLimited(req) {
    const key = pairingClientKey(req)
    const at = Date.now()
    const record = pairAttempts.get(key)
    if (record === undefined || at - record.start > 5 * 60 * 1000) {
      pairAttempts.set(key, { start: at, count: 1 })
      return false
    }
    record.count += 1
    return record.count > 10
  }

  function secureCookie(req) {
    if (req.socket.encrypted === true) return true
    if (String(req.headers['x-forwarded-proto'] ?? '') === 'https') return true
    return currentOrigin()?.startsWith('https://') === true
  }

  function hostAllowed(req) {
    const host = String(req.headers.host ?? '').toLowerCase()
    const expected = currentHost()
    if (expected !== undefined) return host === expected
    if (config.allowDev !== true) return false
    const port = req.socket.localPort
    return host === `127.0.0.1:${port}` || host === `localhost:${port}`
  }

  /** Host/Origin fence for the phone origin. No CORS is ever offered. */
  function trustRejection(req) {
    if (!hostAllowed(req)) return 403
    const host = String(req.headers.host ?? '').toLowerCase()
    const origin = req.headers.origin
    const expectedOrigin = currentOrigin()
    if (origin !== undefined) {
      if (expectedOrigin !== undefined) {
        if (origin !== expectedOrigin) return 403
      } else if (config.allowDev === true) {
        if (origin !== `http://${host}` && origin !== `https://${host}`) return 403
      } else {
        return 403
      }
    } else if (MUTATING_METHODS.has(String(req.method ?? '').toUpperCase())
      && expectedOrigin !== undefined
      && config.allowDev !== true) {
      return 403
    }
    const site = req.headers['sec-fetch-site']
    if (site !== undefined && site !== 'same-origin' && site !== 'none') return 403
    return undefined
  }

  function authenticateDevice(req) {
    const device = sessions?.authenticate?.(req)
    if (device === undefined) return undefined
    lastSeenAt = Date.now()
    return device
  }

  function pairingCookie(req, sessionToken) {
    return sessions.sessionCookie(sessionToken, secureCookie(req))
  }

  function pendingFor(reqId) {
    if (typeof reqId !== 'string' || reqId.length === 0) return undefined
    const items = store?.items
    if (items !== undefined && typeof items.get === 'function') return items.get(reqId)
    const list = typeof store?.list === 'function' ? store.list() : []
    return list.find(item => item.reqId === reqId)
  }

  function claimRejection(pending, body) {
    if (pending === undefined) return 'not-found'
    if (typeof body?.sessionId !== 'string' || body.sessionId !== pending.sessionId) return 'claim-mismatch'
    if ((body?.callId ?? null) !== (pending.callId ?? null)) return 'claim-mismatch'
    return undefined
  }

  function claimOf(body) {
    return {
      sessionId: typeof body?.sessionId === 'string' ? body.sessionId : undefined,
      callId: body?.callId ?? null,
    }
  }

  function recordAudit(event) {
    try {
      audit?.record?.(event)
    } catch { /* audit must not break an answer */ }
  }

  function sendSse(res, event, data) {
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
  }

  function activeDeviceIds() {
    const devices = typeof sessions?.listDevices === 'function' ? sessions.listDevices() : []
    return new Set(devices.map(device => device.id))
  }

  function openEvents(req, res, device) {
    if (clients.size >= MAX_SSE_CLIENTS) {
      sendJson(res, 429, { ok: false, error: 'too-many-streams' })
      return
    }
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    })
    res.write(': connected\n\n')
    clients.add(res)
    clientDevices.set(res, device.id)
    sendSse(res, 'snapshot', { requests: store.list() })
    const ping = setInterval(() => {
      if (!activeDeviceIds().has(device.id)) {
        clearInterval(ping)
        clients.delete(res)
        clientDevices.delete(res)
        try { res.end() } catch { /* already closed */ }
        return
      }
      try { res.write(': ping\n\n') } catch { /* closed below */ }
    }, 20_000)
    ping.unref?.()
    req.on('close', () => {
      clearInterval(ping)
      clients.delete(res)
      clientDevices.delete(res)
    })
  }

  function broadcast(event, data) {
    const active = activeDeviceIds()
    for (const res of [...clients]) {
      const deviceId = clientDevices.get(res)
      if (deviceId === undefined || !active.has(deviceId)) {
        clients.delete(res)
        clientDevices.delete(res)
        try { res.end() } catch { /* already closed */ }
        continue
      }
      try {
        sendSse(res, event, data)
      } catch {
        clients.delete(res)
        clientDevices.delete(res)
      }
    }
  }

  async function serveStatic(req, res, pathname) {
    const entry = STATIC.get(pathname)
    if (entry === undefined) return false
    const [name, type] = entry
    try {
      const body = await readFile(join(config.publicDir, name))
      res.writeHead(200, {
        'content-type': type,
        'cache-control': 'no-cache',
      })
      res.end(body)
      return true
    } catch {
      sendJson(res, 404, { ok: false, error: 'not-found' })
      return true
    }
  }

  async function handler(req, res) {
    const rejected = trustRejection(req)
    if (rejected !== undefined) {
      sendJson(res, rejected, { ok: false, error: 'forbidden' })
      return
    }

    const url = new URL(req.url ?? '/', 'http://cue9.local')
    const pathname = url.pathname

    // GET /?token= is only the app shell. The PWA asks the user to tap Pair;
    // POST /api/pair is the one and only pairing consumer.
    if (req.method === 'GET' && pathname === '/api/health') {
      sendJson(res, 200, { ok: true })
      return
    }

    // Pairing from the installed web app (after it already loaded the shell).
    if (req.method === 'POST' && pathname === '/api/pair') {
      if (req.headers['x-cue9-phone'] !== '1') {
        sendJson(res, 403, { ok: false, error: 'forbidden' })
        return
      }
      if (pairingRateLimited(req)) {
        sendJson(res, 429, { ok: false, error: 'too-many-attempts' })
        return
      }
      let body
      try {
        body = await readJson(req)
      } catch (error) {
        sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        return
      }
      const token = typeof body?.token === 'string' ? body.token : ''
      const result = sessions?.consumePairing?.(token)
      if (result === undefined) {
        sendJson(res, 403, { ok: false, error: 'not-paired' })
        return
      }
      pairAttempts.delete(pairingClientKey(req))
      lastSeenAt = Date.now()
      sendJson(res, 200, { ok: true, deviceId: result.deviceId }, {
        'set-cookie': pairingCookie(req, result.sessionToken),
      })
      return
    }

    if (req.method === 'GET' && (pathname === '/api/pending' || pathname === '/api/events' || pathname === '/api/push/key')) {
      const device = authenticateDevice(req)
      if (device === undefined) {
        sendJson(res, 401, { ok: false, error: 'not-paired' })
        return
      }
      if (pathname === '/api/pending') {
        sendJson(res, 200, { requests: store.list() })
        return
      }
      if (pathname === '/api/events') {
        openEvents(req, res, device)
        return
      }
      const sender = resolvePush()
      if (sender?.enabled !== true) {
        sendJson(res, 501, { ok: false, error: 'push-not-configured' })
        return
      }
      sendJson(res, 200, { enabled: true, key: sender.publicKey })
      return
    }

    if (req.method === 'POST' && pathname.startsWith('/api/')) {
      const device = authenticateDevice(req)
      if (device === undefined) {
        sendJson(res, 401, { ok: false, error: 'not-paired' })
        return
      }
      if (req.headers['x-cue9-phone'] !== '1') {
        sendJson(res, 403, { ok: false, error: 'forbidden' })
        return
      }
      let body
      try {
        body = await readJson(req)
      } catch (error) {
        sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        return
      }

      if (pathname === '/api/ack' || pathname === '/api/answer' || pathname === '/api/handoff') {
        const reqId = typeof body?.reqId === 'string' ? body.reqId : ''
        const pending = pendingFor(reqId)
        const rejection = claimRejection(pending, body)
        if (rejection !== undefined) {
          sendJson(res, rejection === 'not-found' ? 404 : 409, { ok: false, error: rejection })
          return
        }
        const claim = claimOf(body)
        if (pathname === '/api/ack') {
          const result = store.ack(reqId, 'phone', claim)
          const status = resultStatus(result)
          if (status === 200) {
            recordAudit({
              source: 'phone',
              principal: device.id,
              deviceId: device.id,
              reqId,
              sessionId: pending.sessionId,
              kind: pending.kind,
              outcome: 'ack',
            })
          }
          sendJson(res, status, status === 200 ? { ok: true } : { ok: false, error: resultError(result) })
          return
        }
        if (pathname === '/api/answer') {
          const result = store.answer(reqId, body, 'phone', claim)
          const status = resultStatus(result)
          if (status === 200) {
            recordAudit({
              source: 'phone',
              principal: device.id,
              deviceId: device.id,
              reqId,
              sessionId: pending.sessionId,
              kind: pending.kind,
              outcome: pending.kind === 'approval' ? String(body?.outcome ?? 'answered') : 'answered',
            })
          }
          sendJson(res, status, status === 200 ? { ok: true } : { ok: false, error: resultError(result) })
          return
        }
        const result = await store.handoff(reqId, 'phone', claim)
        const status = resultStatus(result)
        if (status === 200) {
          recordAudit({
            source: 'phone',
            principal: device.id,
            deviceId: device.id,
            reqId,
            sessionId: pending.sessionId,
            kind: pending.kind,
            outcome: 'handoff',
          })
        }
        sendJson(res, status, status === 200 ? { ok: true } : { ok: false, error: resultError(result) })
        return
      }

      if (pathname === '/api/push/subscribe') {
        const sender = resolvePush()
        if (sender?.enabled !== true) {
          sendJson(res, 501, { ok: false, error: 'push-not-configured' })
          return
        }
        const result = sender.subscribe(device.id, body?.subscription)
        sendJson(res, result.ok ? 200 : 400, result)
        return
      }

      if (pathname === '/api/push/unsubscribe') {
        const sender = resolvePush()
        if (sender?.enabled === true) sender.removeDevice(device.id)
        sendJson(res, 200, { ok: true })
        return
      }

      sendJson(res, 404, { ok: false, error: 'not-found' })
      return
    }

    if (req.method === 'GET' && (await serveStatic(req, res, pathname))) return
    sendJson(res, 404, { ok: false, error: 'not-found' })
  }

  const servers = new Set()
  let started = false
  let boundPort
  let lanPort

  const onRequest = (req, res) => {
    setSecurityHeaders(req, res)
    void handler(req, res).catch((error) => {
      log(`[cue9-phone] request failed: ${error?.message ?? error}`)
      if (!res.headersSent) sendJson(res, 500, { ok: false, error: 'internal' })
      else res.destroy()
    })
  }

  function listen(server, port, host) {
    return new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(port, host, () => {
        server.off('error', reject)
        const address = server.address()
        resolve(typeof address === 'object' && address !== null ? address.port : port)
      })
    })
  }

  function close(server) {
    return new Promise(resolve => server.close(() => resolve()))
  }

  return {
    broadcast,
    get server() { return [...servers][0] },
    get clients() { return clients },
    get lastSeenAt() { return lastSeenAt },
    get port() { return boundPort },
    get lanPort() { return lanPort },
    async start() {
      if (started) return
      const http = createHttpServer(onRequest)
      boundPort = await listen(http, config.port, config.host)
      servers.add(http)

      const lan = config.lan
      if (lan?.host && lan?.port && lan?.certFile && lan?.keyFile) {
        try {
          const https = createHttpsServer({
            cert: readFileSync(lan.certFile),
            key: readFileSync(lan.keyFile),
          }, onRequest)
          lanPort = await listen(https, lan.port, lan.host)
          servers.add(https)
        } catch (error) {
          log(`[cue9-phone] LAN HTTPS listener unavailable: ${error?.message ?? error}`)
        }
      }

      started = true
      const origin = currentOrigin() ?? `http://${config.host}:${boundPort}`
      log(`[cue9-phone] phone surface listening at ${origin}`)
    },
    async stop() {
      if (!started) return
      started = false
      for (const res of clients) {
        try { res.end() } catch { /* already closed */ }
      }
      clients.clear()
      clientDevices.clear()
      await Promise.all([...servers].map(server => close(server)))
      servers.clear()
      boundPort = undefined
      lanPort = undefined
    },
  }
}
