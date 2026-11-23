import test from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createSessions } from '../lib/sessions.js'
import { createPhoneServer } from '../lib/phone-server.js'
import { RequestStore } from '../lib/store.js'
import { PUBLIC_DIR } from '../lib/config.js'

class FakeStore {
  constructor() {
    this.items = new Map()
    this.answerCalls = []
    this.ackCalls = []
    this.handoffCalls = []
  }

  add(overrides = {}) {
    const pending = {
      reqId: 'r1',
      kind: 'approval',
      sessionId: 's1',
      callId: 'c1',
      toolName: 'bash',
      command: 'echo hi',
      ...overrides,
    }
    this.items.set(pending.reqId, pending)
    return pending
  }

  list() {
    return [...this.items.values()]
  }

  answer(reqId, value, source, claim) {
    this.answerCalls.push({ reqId, value, source, claim })
    const pending = this.items.get(reqId)
    if (pending === undefined) return { ok: false, error: 'not-found' }
    if (claim?.sessionId !== pending.sessionId || (claim?.callId ?? null) !== (pending.callId ?? null)) {
      return { ok: false, error: 'claim-mismatch' }
    }
    if (pending.kind === 'approval' && !['allowed-once', 'rejected'].includes(value?.outcome)) {
      return { ok: false, error: 'invalid-answer' }
    }
    this.items.delete(reqId)
    return { ok: true }
  }

  ack(reqId, source, claim) {
    this.ackCalls.push({ reqId, source, claim })
    const pending = this.items.get(reqId)
    if (pending === undefined) return { ok: false, error: 'not-found' }
    if (claim?.sessionId !== pending.sessionId || (claim?.callId ?? null) !== (pending.callId ?? null)) {
      return { ok: false, error: 'claim-mismatch' }
    }
    this.acknowledged = reqId
    return { ok: true }
  }

  async handoff(reqId, source, claim) {
    this.handoffCalls.push({ reqId, source, claim })
    const pending = this.items.get(reqId)
    if (pending === undefined) return { ok: false, error: 'not-found' }
    if (claim?.sessionId !== pending.sessionId || (claim?.callId ?? null) !== (pending.callId ?? null)) {
      return { ok: false, error: 'claim-mismatch' }
    }
    this.items.delete(reqId)
    return { ok: true }
  }
}

function fakePush() {
  return {
    enabled: true,
    publicKey: 'test-push-key',
    subscriptions: [],
    hasSubscriptions() { return this.subscriptions.length > 0 },
    subscribe(deviceId, subscription) {
      this.subscriptions.push({ deviceId, subscription })
      return { ok: true }
    },
    removeDevice(deviceId) {
      this.removedDevice = deviceId
      return { ok: true, removed: 1 }
    },
    removeAll() { return { ok: true, removed: 0 } },
    test: async () => ({ ok: true, sent: 1 }),
    notify: async () => {},
  }
}

function request(port, path, options = {}) {
  const { method = 'GET', headers = {}, body } = options
  return new Promise((resolve, reject) => {
    const requestHeaders = { ...headers }
    if (body !== undefined) {
      requestHeaders['content-type'] = requestHeaders['content-type'] ?? 'application/json'
      requestHeaders['content-length'] = Buffer.byteLength(body)
    }
    const req = http.request({
      host: '127.0.0.1',
      port,
      path,
      method,
      headers: requestHeaders,
    }, (res) => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }))
    })
    req.on('error', reject)
    if (body !== undefined) req.write(body)
    req.end()
  })
}

function setCookieOf(response) {
  const value = response.headers['set-cookie']
  const first = Array.isArray(value) ? value[0] : value
  return typeof first === 'string' ? first : undefined
}

function cookieOf(response) {
  const cookie = setCookieOf(response)
  const match = cookie === undefined ? null : /^cue9_session=([^;]+)/.exec(cookie)
  return match === null ? undefined : `cue9_session=${match[1]}`
}

async function setup(options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'cue9-phone-'))
  const sessions = createSessions({ dir, log: () => {} })
  const store = options.store ?? new FakeStore()
  const push = options.push ?? fakePush()
  const audit = options.audit
  const config = {
    port: 0,
    host: '127.0.0.1',
    publicDir: PUBLIC_DIR,
    allowDev: true,
    ...options.config,
  }
  const phone = createPhoneServer({ config, store, sessions, push, audit, log: () => {} })
  await phone.start()
  const host = options.host ?? `127.0.0.1:${phone.port}`
  return { dir, sessions, store, push, phone, host, audit, config }
}

async function pair(host, phone, sessions, origin) {
  const { token } = sessions.mintPairing()
  const landing = await request(phone.port, `/pair?token=${encodeURIComponent(token)}`, {
    headers: { Host: host },
  })
  assert.equal(landing.status, 200)
  assert.equal(setCookieOf(landing), undefined)
  const response = await post(
    phone,
    host,
    '/api/pair',
    { token },
    origin === undefined ? {} : { Origin: origin },
  )
  assert.equal(response.status, 200)
  const body = JSON.parse(response.body)
  return { cookie: cookieOf(response), response, deviceId: body.deviceId, token }
}

function post(phone, host, path, body, extraHeaders = {}) {
  return request(phone.port, path, {
    method: 'POST',
    headers: {
      Host: host,
      'x-cue9-phone': '1',
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  })
}

function openSse(phone, host, cookie) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: phone.port,
      path: '/api/events',
      headers: { Host: host, cookie },
    }, (res) => {
      res.on('error', () => {})
      res.resume()
      resolve({ req, res, status: res.statusCode, headers: res.headers })
    })
    req.on('error', reject)
    req.end()
  })
}

async function waitFor(predicate, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  assert.fail('timed out waiting for condition')
}

test('pairing GET serves the shell without consuming; POST is the one-time consumer', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { token } = ctx.sessions.mintPairing()
  const first = await request(ctx.phone.port, `/?token=${encodeURIComponent(token)}`, {
    headers: { Host: ctx.host },
  })
  assert.equal(first.status, 200)
  assert.equal(setCookieOf(first), undefined)
  assert.match(first.body, /<script type="module" src="\/app.js">/)

  const repeat = await request(ctx.phone.port, `/?token=${encodeURIComponent(token)}`, {
    headers: { Host: ctx.host },
  })
  assert.equal(repeat.status, 200)
  assert.equal(setCookieOf(repeat), undefined)

  const paired = await post(ctx.phone, ctx.host, '/api/pair', { token })
  assert.equal(paired.status, 200)
  const cookie = cookieOf(paired)
  assert.ok(cookie)
  assert.equal(JSON.parse(paired.body).deviceId, ctx.sessions.listDevices()[0].id)
  assert.match(setCookieOf(paired), /HttpOnly/)
  assert.match(setCookieOf(paired), /SameSite=Strict/)

  const replay = await post(ctx.phone, ctx.host, '/api/pair', { token })
  assert.equal(replay.status, 403)

  const noCookie = await request(ctx.phone.port, '/api/pending', { headers: { Host: ctx.host } })
  assert.equal(noCookie.status, 401)

  const pending = await request(ctx.phone.port, '/api/pending', {
    headers: { Host: ctx.host, cookie },
  })
  assert.equal(pending.status, 200)
  assert.deepEqual(JSON.parse(pending.body).requests, [])
})

test('/pair is a lean landing page with no PWA identity and no GET consume', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { token } = ctx.sessions.mintPairing()
  const page = await request(ctx.phone.port, `/pair?token=${encodeURIComponent(token)}`, {
    headers: { Host: ctx.host },
  })
  assert.equal(page.status, 200)
  assert.match(page.headers['content-type'], /^text\/html/)
  assert.match(page.body, /<title>Connect cue9<\/title>/)
  assert.match(page.body, /id="connect"/)
  assert.doesNotMatch(page.body, /<input/i)
  assert.doesNotMatch(page.body, /rel=["']manifest["']/i)
  assert.doesNotMatch(page.body, /serviceWorker/i)
  assert.doesNotMatch(page.body, /sw\.js/i)
  assert.doesNotMatch(page.body, /apple-mobile-web-app/i)
  assert.match(page.body, /Add to Home Screen/)
  assert.match(page.body, /Enable alerts/)
  assert.equal(page.body.includes(token), false)
  assert.equal(setCookieOf(page), undefined)
  assert.equal(ctx.sessions.listDevices().length, 0)
  assert.equal(page.headers['referrer-policy'], 'no-referrer')
  assert.equal(page.headers['x-content-type-options'], 'nosniff')

  const script = await request(ctx.phone.port, '/pair.js', { headers: { Host: ctx.host } })
  assert.equal(script.status, 200)
  assert.match(script.headers['content-type'], /^text\/javascript/)
  assert.doesNotMatch(script.body, /serviceWorker/i)
  assert.doesNotMatch(script.body, /sw\.js/i)
  assert.match(script.body, /replaceState/)
  assert.match(script.body, /\/api\/pair/)
  assert.match(script.body, /x-cue9-phone/)

  const style = await request(ctx.phone.port, '/pair.css', { headers: { Host: ctx.host } })
  assert.equal(style.status, 200)
  assert.match(style.headers['content-type'], /^text\/css/)

  const paired = await post(ctx.phone, ctx.host, '/api/pair', { token })
  assert.equal(paired.status, 200)
  assert.ok(cookieOf(paired))
  assert.equal(ctx.sessions.listDevices().length, 1)
})

test('minted pairing URL uses the lean /pair page', () => {
  const source = readFileSync(new URL('../index.js', import.meta.url), 'utf8')
  assert.match(source, /url:\s*`\$\{origin\}\/pair\?token=\$\{encodeURIComponent\(minted\.token\)\}`/)
  assert.doesNotMatch(source, /url:\s*`\$\{origin\}\/\?token=\$\{encodeURIComponent\(minted\.token\)\}`/)
})

test('POST /api/pair consumes a one-time token and returns a cookie', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { token } = ctx.sessions.mintPairing()
  const response = await post(ctx.phone, ctx.host, '/api/pair', { token })
  assert.equal(response.status, 200)
  const cookie = cookieOf(response)
  assert.ok(cookie)
  assert.match(response.body, /"deviceId":/)
  const replay = await post(ctx.phone, ctx.host, '/api/pair', { token })
  assert.equal(replay.status, 403)
})

test('Host and Origin fences reject evil origins and cross-site requests', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const evilHost = await request(ctx.phone.port, '/api/health', { headers: { Host: 'evil.com' } })
  assert.equal(evilHost.status, 403)

  const evilStatic = await request(ctx.phone.port, '/styles.css', { headers: { Host: 'evil.com' } })
  assert.equal(evilStatic.status, 403)

  const goodStatic = await request(ctx.phone.port, '/styles.css', { headers: { Host: ctx.host } })
  assert.equal(goodStatic.status, 200)

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const pending = ctx.store.add({ reqId: 'r1', sessionId: 's1', callId: 'c1' })
  const evilOrigin = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's1', callId: 'c1', outcome: 'allowed-once',
  }, { Origin: 'https://evil.com' })
  assert.equal(evilOrigin.status, 403)

  const crossSite = await request(ctx.phone.port, '/api/pending', {
    headers: { Host: ctx.host, cookie, 'Sec-Fetch-Site': 'cross-site' },
  })
  assert.equal(crossSite.status, 403)

  const goodHealth = await request(ctx.phone.port, '/api/health', { headers: { Host: ctx.host } })
  assert.equal(goodHealth.status, 200)
})

test('answers and acks require the request claim', async t => {
  const audit = { records: [], record(event) { this.records.push(event) } }
  const ctx = await setup({ audit })
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const pending = ctx.store.add({ reqId: 'r1', sessionId: 's1', callId: 'c1' })

  const missingClaim = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, outcome: 'allowed-once',
  }, { cookie })
  assert.equal(missingClaim.status, 409)

  const wrongCall = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's1', callId: 'nope', outcome: 'allowed-once',
  }, { cookie })
  assert.equal(wrongCall.status, 409)

  const accepted = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's1', callId: 'c1', outcome: 'allowed-once',
  }, { cookie })
  assert.equal(accepted.status, 200)
  assert.equal(ctx.store.answerCalls.length, 1)
  assert.deepEqual(ctx.store.answerCalls[0].claim, { sessionId: 's1', callId: 'c1' })
  assert.equal(audit.records[0].source, 'phone')
  assert.equal(audit.records[0].deviceId, ctx.sessions.listDevices()[0].id)

  const stale = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's1', callId: 'c1', outcome: 'allowed-once',
  }, { cookie })
  assert.equal(stale.status, 404)

  const ackPending = ctx.store.add({ reqId: 'r2', sessionId: 's2', callId: 'c2' })
  const ackMissing = await post(ctx.phone, ctx.host, '/api/ack', { reqId: ackPending.reqId }, { cookie })
  assert.equal(ackMissing.status, 409)
  const ack = await post(ctx.phone, ctx.host, '/api/ack', {
    reqId: ackPending.reqId, sessionId: 's2', callId: 'c2',
  }, { cookie })
  assert.equal(ack.status, 200)
  assert.equal(ctx.store.ackCalls[0].claim.sessionId, 's2')

  const handoffPending = ctx.store.add({ reqId: 'r3', sessionId: 's3', callId: null, kind: 'question' })
  const handoffWrong = await post(ctx.phone, ctx.host, '/api/handoff', {
    reqId: handoffPending.reqId, sessionId: 's3', callId: 'wrong',
  }, { cookie })
  assert.equal(handoffWrong.status, 409)
  const handoff = await post(ctx.phone, ctx.host, '/api/handoff', {
    reqId: handoffPending.reqId, sessionId: 's3',
  }, { cookie })
  assert.equal(handoff.status, 200)
  assert.equal(ctx.store.handoffCalls[0].claim.callId, null)
})

test('push routes use the authenticated device', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const key = await request(ctx.phone.port, '/api/push/key', { headers: { Host: ctx.host, cookie } })
  assert.equal(key.status, 200)
  assert.equal(JSON.parse(key.body).key, 'test-push-key')

  const subscribe = await post(ctx.phone, ctx.host, '/api/push/subscribe', {
    subscription: { endpoint: 'https://push.example/1', keys: { p256dh: 'p', auth: 'a' } },
  }, { cookie })
  assert.equal(subscribe.status, 200)
  assert.equal(ctx.push.subscriptions.length, 1)
  assert.equal(ctx.push.subscriptions[0].deviceId, ctx.sessions.listDevices()[0].id)

  const unsubscribe = await post(ctx.phone, ctx.host, '/api/push/unsubscribe', {}, { cookie })
  assert.equal(unsubscribe.status, 200)
  assert.equal(ctx.push.removedDevice, ctx.sessions.listDevices()[0].id)
})

test('a revoked session loses access', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const device = ctx.sessions.listDevices()[0]
  const before = await request(ctx.phone.port, '/api/pending', { headers: { Host: ctx.host, cookie } })
  assert.equal(before.status, 200)
  assert.equal(ctx.sessions.revoke(device.id), true)
  const after = await request(ctx.phone.port, '/api/pending', { headers: { Host: ctx.host, cookie } })
  assert.equal(after.status, 401)
})

test('pairing rate limit keys on the first forwarded peer and only on POST', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const peerA = '198.51.100.1, 10.0.0.1'
  const badA = () => post(ctx.phone, ctx.host, '/api/pair', { token: 'invalid' }, {
    'x-forwarded-for': peerA,
  })
  for (let i = 0; i < 10; i += 1) {
    const response = await badA()
    assert.equal(response.status, 403)
  }
  const limitedA = await badA()
  assert.equal(limitedA.status, 429)

  const peerB = await post(ctx.phone, ctx.host, '/api/pair', { token: 'invalid' }, {
    'x-forwarded-for': '198.51.100.2',
  })
  assert.equal(peerB.status, 403)

  for (let i = 0; i < 20; i += 1) {
    const shell = await request(ctx.phone.port, '/?token=still-not-consumed', {
      headers: { Host: ctx.host },
    })
    assert.equal(shell.status, 200)
    assert.equal(setCookieOf(shell), undefined)
  }
  const stillLimited = await badA()
  assert.equal(stillLimited.status, 429)

  const peerC = '198.51.100.3'
  for (let i = 0; i < 9; i += 1) {
    const response = await post(ctx.phone, ctx.host, '/api/pair', { token: 'invalid' }, {
      'x-forwarded-for': peerC,
    })
    assert.equal(response.status, 403)
  }
  const { token } = ctx.sessions.mintPairing()
  const success = await post(ctx.phone, ctx.host, '/api/pair', { token }, {
    'x-forwarded-for': peerC,
  })
  assert.equal(success.status, 200)
  const afterSuccess = await post(ctx.phone, ctx.host, '/api/pair', { token: 'invalid' }, {
    'x-forwarded-for': peerC,
  })
  assert.equal(afterSuccess.status, 403)
})

test('security headers are set on static, API, SSE and rejection responses', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })
  const csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

  const health = await request(ctx.phone.port, '/api/health', { headers: { Host: ctx.host } })
  assert.equal(health.status, 200)
  assert.equal(health.headers['content-security-policy'], csp)
  assert.equal(health.headers['x-content-type-options'], 'nosniff')
  assert.equal(health.headers['x-frame-options'], 'DENY')
  assert.equal(health.headers['referrer-policy'], 'no-referrer')
  assert.equal(health.headers['permissions-policy'], 'camera=(), microphone=(), geolocation=()')
  assert.equal(health.headers['strict-transport-security'], undefined)
  assert.equal(health.headers['access-control-allow-origin'], undefined)

  const forwardedHttps = await request(ctx.phone.port, '/api/health', {
    headers: { Host: ctx.host, 'x-forwarded-proto': 'https,http' },
  })
  assert.equal(forwardedHttps.headers['strict-transport-security'], 'max-age=15552000')

  const shell = await request(ctx.phone.port, '/', { headers: { Host: ctx.host } })
  assert.equal(shell.status, 200)
  assert.equal(shell.headers['content-security-policy'], csp)

  const forbidden = await request(ctx.phone.port, '/api/health', { headers: { Host: 'evil.com' } })
  assert.equal(forbidden.status, 403)
  assert.equal(forbidden.headers['content-security-policy'], csp)

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const sse = await openSse(ctx.phone, ctx.host, cookie)
  assert.equal(sse.status, 200)
  assert.equal(sse.headers['content-security-policy'], csp)
  assert.equal(sse.headers['strict-transport-security'], undefined)
  sse.req.destroy()
  await waitFor(() => ctx.phone.clients.size === 0)
})

test('caps phone SSE at eight total and frees slots on close', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const streams = []
  for (let i = 0; i < 8; i += 1) {
    const stream = await openSse(ctx.phone, ctx.host, cookie)
    assert.equal(stream.status, 200)
    streams.push(stream)
    await waitFor(() => ctx.phone.clients.size === i + 1)
  }

  const ninth = await request(ctx.phone.port, '/api/events', { headers: { Host: ctx.host, cookie } })
  assert.equal(ninth.status, 429)
  assert.match(ninth.headers['content-type'], /application\/json/)
  assert.equal(JSON.parse(ninth.body).error, 'too-many-streams')

  streams[0].req.destroy()
  await waitFor(() => ctx.phone.clients.size === 7)

  const tenth = await openSse(ctx.phone, ctx.host, cookie)
  assert.equal(tenth.status, 200)
  streams.push(tenth)
  await waitFor(() => ctx.phone.clients.size === 8)

  for (const stream of streams) stream.req.destroy()
  await waitFor(() => ctx.phone.clients.size === 0)
})

test('non-dev mode requires publicOrigin Host and Origin', async t => {
  const ctx = await setup({
    config: {
      allowDev: false,
      publicOrigin: 'https://phone.example:8443',
    },
    host: 'phone.example:8443',
  })
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const evil = await request(ctx.phone.port, '/api/health', { headers: { Host: 'evil.com' } })
  assert.equal(evil.status, 403)

  const noOrigin = await post(ctx.phone, ctx.host, '/api/pair', { token: 'x' })
  assert.equal(noOrigin.status, 403)

  const evilOrigin = await post(ctx.phone, ctx.host, '/api/pair', { token: 'x' }, { Origin: 'https://evil.com' })
  assert.equal(evilOrigin.status, 403)

  const { token } = ctx.sessions.mintPairing()
  const shell = await request(ctx.phone.port, `/?token=${encodeURIComponent(token)}`, {
    headers: { Host: ctx.host },
  })
  assert.equal(shell.status, 200)
  assert.equal(setCookieOf(shell), undefined)

  const pairResponse = await post(ctx.phone, ctx.host, '/api/pair', { token }, {
    Origin: 'https://phone.example:8443',
  })
  assert.equal(pairResponse.status, 200)
  const cookie = cookieOf(pairResponse)
  assert.ok(cookie)
  assert.equal(JSON.parse(pairResponse.body).deviceId, ctx.sessions.listDevices()[0].id)
  const pending = await request(ctx.phone.port, '/api/pending', { headers: { Host: ctx.host, cookie } })
  assert.equal(pending.status, 200)
})

test('picks up a publicOrigin applied after creation', async t => {
  const ctx = await setup()
  t.after(async () => { await ctx.phone.stop(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const before = await request(ctx.phone.port, '/api/health', {
    headers: { Host: 'phone.example:8443' },
  })
  assert.equal(before.status, 403)

  ctx.config.publicOrigin = 'https://phone.example:8443'
  await ctx.phone.stop()
  await ctx.phone.start()

  const after = await request(ctx.phone.port, '/api/health', {
    headers: { Host: 'phone.example:8443' },
  })
  assert.equal(after.status, 200)
})

test('works end to end with the real claim-aware request store', async t => {
  const store = new RequestStore()
  const ctx = await setup({ store })
  t.after(async () => { await ctx.phone.stop(); store.dispose(); rmSync(ctx.dir, { recursive: true, force: true }) })

  const { cookie } = await pair(ctx.host, ctx.phone, ctx.sessions)
  const pending = store.create({
    kind: 'approval',
    sessionId: 's-real',
    callId: 'c-real',
    toolName: 'bash',
    args: { command: 'echo hi' },
    next: async () => 'rejected',
  })

  const invalid = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's-real', callId: 'c-real', outcome: 'not-a-decision',
  }, { cookie })
  assert.equal(invalid.status, 400)

  const accepted = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's-real', callId: 'c-real', outcome: 'allowed-once',
  }, { cookie })
  assert.equal(accepted.status, 200)
  assert.equal(await pending.promise, 'allowed-once')

  const stale = await post(ctx.phone, ctx.host, '/api/answer', {
    reqId: pending.reqId, sessionId: 's-real', callId: 'c-real', outcome: 'rejected',
  }, { cookie })
  assert.equal(stale.status, 404)

  const ackPending = store.create({
    kind: 'approval',
    sessionId: 's-ack',
    callId: 'c-ack',
    toolName: 'bash',
    args: { command: 'echo hi' },
    next: async () => 'rejected',
  })
  const ack = await post(ctx.phone, ctx.host, '/api/ack', {
    reqId: ackPending.reqId, sessionId: 's-ack', callId: 'c-ack',
  }, { cookie })
  assert.equal(ack.status, 200)
  assert.equal(store.ackedBy(ackPending.reqId, 'phone'), true)
  ackPending.promise.catch(() => {})
  store.dispose()
})
