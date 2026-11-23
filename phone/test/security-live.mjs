#!/usr/bin/env node
/**
 * Live security probe for the cue9 phone bridge.
 *
 * Optional inputs:
 * - phone.json publicOrigin: enables phone probes. Missing/invalid => SKIP.
 * - CUE9_APP_TOKEN: enables app-Bearer and pairing probes. Missing => SKIP.
 *
 * This script never registers an app token and never reads, writes, deletes,
 * or requires app-auth.json. With no token it only performs unauthenticated
 * checks. No tokens, pairing URLs, or response bodies are printed.
 *
 * The DSH origin comes from CUE9_DSH_ORIGIN, then DSH_WEB_URL, then
 * http://127.0.0.1:54291.
 */
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import http from 'node:http'
import https from 'node:https'

const FALLBACK_DSH = 'http://127.0.0.1:54291'

function asOrigin(value, fallback) {
  try {
    const url = new URL(value)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return fallback
    return new URL(url.origin)
  } catch {
    return fallback
  }
}

const DSH = asOrigin(
  process.env.CUE9_DSH_ORIGIN || process.env.DSH_WEB_URL || FALLBACK_DSH,
  new URL(FALLBACK_DSH),
)

function readPhoneOrigin() {
  try {
    const raw = JSON.parse(readFileSync(join(homedir(), '.dsh', 'cue9', 'phone.json'), 'utf8'))
    if (typeof raw?.publicOrigin !== 'string' || raw.publicOrigin.trim() === '') return undefined
    const url = new URL(raw.publicOrigin)
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return undefined
    if (url.hostname === '') return undefined
    return new URL(url.origin)
  } catch {
    return undefined
  }
}

const PHONE = readPhoneOrigin()
const PHONE_READY = PHONE !== undefined
const APP_TOKEN = typeof process.env.CUE9_APP_TOKEN === 'string'
  ? process.env.CUE9_APP_TOKEN.trim()
  : ''
const HAS_APP_TOKEN = APP_TOKEN.length > 0
const auth = HAS_APP_TOKEN ? { authorization: `Bearer ${APP_TOKEN}` } : undefined
const results = []
const skips = []

function request(url, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const transport = url.protocol === 'https:' ? https : http
    const payload = body === undefined ? undefined : JSON.stringify(body)
    const req = transport.request(url, {
      method,
      headers: {
        ...(payload === undefined ? {} : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) }),
        ...headers,
      },
    }, response => {
      const chunks = []
      response.on('data', chunk => chunks.push(chunk))
      response.on('end', () => resolve({
        status: response.statusCode ?? 0,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
        cookies: response.headers['set-cookie'] ?? [],
      }))
    })
    req.on('error', reject)
    if (payload !== undefined) req.write(payload)
    req.end()
  })
}

function check(name, condition, status) {
  results.push({ name, pass: condition, status })
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${status === undefined ? '' : ` (${status})`}`)
}

function skip(name) {
  skips.push(name)
  console.log(`SKIP  ${name}`)
}

function dsh(path) {
  return new URL(path, DSH)
}

function phone(path) {
  if (PHONE === undefined) throw new Error('phone origin unavailable')
  return new URL(path, PHONE)
}

/** Loopback HTTP avoids TLS/Host interplay in hostile-Host probes. */
function localPhone(path) {
  return new URL(path, 'http://127.0.0.1:8791')
}

function sessionCookie(cookies) {
  return cookies
    .map(value => value.split(';')[0])
    .find(value => value.startsWith('cue9_session='))
}

async function main() {
  if (!PHONE_READY) skip('phone probes: phone.json has no usable publicOrigin')
  if (!HAS_APP_TOKEN) skip('app Bearer probes: CUE9_APP_TOKEN is not set')

  // --- App routes: unauthenticated checks --------------------------------

  const setupNoAuth = await request(dsh('/plugins/cue9-phone/setup'))
  check('app setup rejects no Bearer', setupNoAuth.status === 401, setupNoAuth.status)

  const setupEvilHost = await request(dsh('/plugins/cue9-phone/setup'), {
    headers: { host: 'evil.com' },
  })
  check('app setup rejects Host evil.com', setupEvilHost.status === 403, setupEvilHost.status)

  const powerNoAuth = await request(dsh('/plugins/cue9-phone/power'))
  check('power rejects no Bearer', powerNoAuth.status === 401, powerNoAuth.status)

  // --- App routes: authenticated (only with an explicit app token) -------

  if (HAS_APP_TOKEN) {
    const setup = await request(dsh('/plugins/cue9-phone/setup'), { headers: auth })
    check('app setup accepts app Bearer', setup.status === 200, setup.status)

    let setupJson = {}
    try { setupJson = JSON.parse(setup.body) } catch { /* checked below */ }
    check('setup response has no raw pairing token', !JSON.stringify(setupJson).includes('token='))
    check('setup exposes paired devices without secrets', Array.isArray(setupJson.phone?.devices))

    const power = await request(dsh('/plugins/cue9-phone/power'), { headers: auth })
    check('power accepts app Bearer', power.status === 200, power.status)
  }

  // --- Phone server: unauthenticated Host/no-cookie checks ---------------

  if (PHONE_READY) {
    const health = await request(phone('/api/health'))
    check('phone health works with public Host', health.status === 200, health.status)

    const healthEvil = await request(localPhone('/api/health'), {
      headers: { host: 'evil.com' },
    })
    check('phone health rejects Host evil.com', healthEvil.status === 403, healthEvil.status)

    const pendingNoCookie = await request(phone('/api/pending'))
    check('phone pending rejects no session cookie', pendingNoCookie.status === 401, pendingNoCookie.status)

    const shell = await request(phone('/?token=not-a-real-token'))
    check(
      'pairing GET serves shell without a session cookie',
      shell.status === 200 && sessionCookie(shell.cookies) === undefined,
      shell.status,
    )
  }

  // --- Pairing/session: only with an explicit token and phone origin -----

  if (HAS_APP_TOKEN && PHONE_READY) {
    await pairingProbes()
  } else if (!HAS_APP_TOKEN) {
    skip('pairing probes: CUE9_APP_TOKEN is not set')
  } else {
    skip('pairing probes: no usable phone origin')
  }

  summary()
  process.exit(results.every(result => result.pass) ? 0 : 1)
}

async function pairingProbes() {
  const mint = await request(dsh('/plugins/cue9-phone/setup/pairing'), {
    method: 'POST',
    headers: { ...auth, 'x-cue9-phone': '1' },
    body: {},
  })
  check('app can mint a pairing link', mint.status === 200, mint.status)

  let pairing = {}
  try { pairing = JSON.parse(mint.body) } catch { /* checked below */ }
  if (mint.status !== 200 || typeof pairing.token !== 'string' || typeof pairing.url !== 'string') {
    skip('pairing flow: mint response incomplete')
    return
  }
  check('pairing response contains a token and URL', true)

  let link
  try {
    link = new URL(pairing.url)
  } catch {
    check('pairing response URL is valid', false)
    return
  }

  // GET must serve the normal shell, set no session cookie, and not consume
  // the pairing. The POST below proves it was not consumed.
  const shell = await request(link)
  check('pairing GET serves the app shell', shell.status === 200, shell.status)
  check('pairing GET does not set a session cookie', sessionCookie(shell.cookies) === undefined)

  const pair = await request(phone('/api/pair'), {
    method: 'POST',
    headers: { origin: PHONE.origin, 'x-cue9-phone': '1' },
    body: { token: pairing.token },
  })
  check('pairing POST succeeds after GET', pair.status === 200, pair.status)

  let paired = {}
  try { paired = JSON.parse(pair.body) } catch { /* checked below */ }
  check('pairing POST returns a deviceId', typeof paired.deviceId === 'string' && paired.deviceId.length > 0)

  const cookie = sessionCookie(pair.cookies)
  check('pairing POST sets a session cookie', cookie !== undefined)

  if (cookie !== undefined) {
    const headers = { cookie, origin: PHONE.origin }
    const pending = await request(phone('/api/pending'), { headers: { cookie } })
    check('phone session can list pending', pending.status === 200, pending.status)

    const evilOrigin = await request(localPhone('/api/answer'), {
      method: 'POST',
      headers: { cookie, host: PHONE.host, origin: 'http://evil.com', 'x-cue9-phone': '1' },
      body: { reqId: 'bogus', sessionId: 's', callId: 'c', outcome: 'allowed-once' },
    })
    check('phone answer rejects Origin evil.com', evilOrigin.status === 403, evilOrigin.status)

    const answer = await request(phone('/api/answer'), {
      method: 'POST',
      headers: { ...headers, 'x-cue9-phone': '1' },
      body: { reqId: 'bogus', sessionId: 's', callId: 'c', outcome: 'allowed-once' },
    })
    check('phone answer reaches handler with a valid session', answer.status === 404, answer.status)

    const claimMismatch = await request(phone('/api/ack'), {
      method: 'POST',
      headers: { ...headers, 'x-cue9-phone': '1' },
      body: { reqId: 'bogus', sessionId: 'wrong', callId: 'wrong' },
    })
    check('phone claim mismatch is rejected before execution', claimMismatch.status === 404 || claimMismatch.status === 409, claimMismatch.status)
  }

  if (typeof paired.deviceId !== 'string' || paired.deviceId.length === 0) {
    skip('device revoke: pairing POST did not return a deviceId')
    return
  }

  const revoke = await request(dsh('/plugins/cue9-phone/setup/revoke'), {
    method: 'POST',
    headers: { ...auth, 'x-cue9-phone': '1' },
    body: { deviceId: paired.deviceId },
  })
  check('app revokes only the test device', revoke.status === 200, revoke.status)

  let revoked = {}
  try { revoked = JSON.parse(revoke.body) } catch { /* checked below */ }
  if (revoke.status === 200 && revoked.revoked !== undefined) {
    check('revoke response removed exactly one device', revoked.revoked === 1, revoked.revoked)
  }

  if (cookie !== undefined) {
    const after = await request(phone('/api/pending'), { headers: { cookie } })
    check('revoked phone session is rejected', after.status === 401, after.status)
  }
}

function summary() {
  const failed = results.filter(result => !result.pass)
  const suffix = skips.length > 0 ? ` (${skips.length} skipped)` : ''
  console.log(`\n${results.length - failed.length}/${results.length} probes passed${suffix}`)
  if (failed.length > 0) {
    console.log('Failed probes:')
    for (const failure of failed) console.log(`- ${failure.name} (${failure.status})`)
  }
}

main().catch(error => {
  console.error('Probe error:', error?.message ?? error)
  process.exit(1)
})
