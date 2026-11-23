import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createAppAuth } from '../lib/app-auth.js'
import { createAudit } from '../lib/audit.js'
import { safeSetupStatus } from '../index.js'

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'cue9-security-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  return dir
}

const TOKEN = 'A'.repeat(43)
const OTHER = 'B'.repeat(43)

test('app auth registers once, is idempotent, and never persists the raw token', (t) => {
  const dir = tempDir(t)
  const path = join(dir, 'app-auth.json')
  const auth = createAppAuth({ path })
  assert.equal(auth.hasToken(), false)
  assert.equal(auth.register(TOKEN), 'created')
  assert.equal(auth.hasToken(), true)
  assert.equal(auth.register(TOKEN), 'ok')
  assert.equal(auth.register(OTHER), 'conflict')

  const raw = readFileSync(path, 'utf8')
  assert.equal(raw.includes(TOKEN), false)
  const parsed = JSON.parse(raw)
  assert.match(parsed.hash, /^[a-f0-9]{64}$/)
  assert.deepEqual(Object.keys(parsed), ['hash'])
  assert.equal(statSync(path).mode & 0o777, 0o600)

  const reopened = createAppAuth({ path })
  assert.equal(reopened.verify({ headers: { authorization: `Bearer ${TOKEN}` } }), true)
  assert.equal(reopened.verify({ headers: { authorization: `bearer ${TOKEN}` } }), true)
  assert.equal(reopened.verify({ headers: { authorization: `Bearer ${OTHER}` } }), false)
  assert.equal(reopened.verify({ headers: { authorization: 'Basic abc' } }), false)
  assert.equal(reopened.verify({ headers: {} }), false)
})

test('app auth rejects invalid token shapes', (t) => {
  const auth = createAppAuth({ path: join(tempDir(t), 'app-auth.json') })
  assert.equal(auth.register('short'), 'invalid')
  assert.equal(auth.register('has spaces and punctuation!'), 'invalid')
  assert.equal(auth.register('A'.repeat(31)), 'invalid')
  assert.equal(auth.hasToken(), false)
  assert.equal(auth.verify({ headers: { authorization: `Bearer ${'A'.repeat(31)}` } }), false)
})

test('app auth rotates only from a valid current token', (t) => {
  const dir = tempDir(t)
  const path = join(dir, 'app-auth.json')
  const auth = createAppAuth({ path })
  assert.equal(auth.rotate(TOKEN, OTHER), 'unauthorized')
  assert.equal(auth.register(TOKEN), 'created')

  assert.equal(auth.rotate('short', OTHER), 'unauthorized')
  assert.equal(auth.rotate(OTHER, TOKEN), 'unauthorized')
  assert.equal(auth.rotate(TOKEN, 'short'), 'invalid')
  assert.equal(auth.verify({ headers: { authorization: `Bearer ${TOKEN}` } }), true)
  assert.equal(auth.rotate(TOKEN, OTHER), 'rotated')
  assert.equal(auth.verify({ headers: { authorization: `Bearer ${TOKEN}` } }), false)
  assert.equal(auth.verify({ headers: { authorization: `Bearer ${OTHER}` } }), true)
  assert.equal(auth.rotate(TOKEN, OTHER), 'unauthorized')

  const raw = readFileSync(path, 'utf8')
  assert.equal(raw.includes(TOKEN), false)
  assert.equal(raw.includes(OTHER), false)
  assert.deepEqual(Object.keys(JSON.parse(raw)), ['hash'])
  assert.equal(statSync(path).mode & 0o777, 0o600)
})

test('setup status trusts ready, never infers it from serve activity', () => {
  const safe = safeSetupStatus({
    ok: true,
    serve: { active: true, url: 'https://example.test:8443' },
    config: { publicOrigin: 'https://example.test:8443' },
    pairing: {
      ready: false,
      origin: 'https://example.test:8443',
      url: 'https://example.test:8443/?token=secret',
      token: 'secret',
    },
  })
  assert.equal(safe.pairing.ready, false)
  assert.equal(safe.pairing.origin, 'https://example.test:8443')
  assert.equal(safe.serve.active, true)
  assert.equal(JSON.stringify(safe).includes('token'), false)
  assert.equal(JSON.stringify(safe).includes('secret'), false)

  const legacy = safeSetupStatus({
    pairing: { public: true, url: 'https://example.test:8443/?token=secret' },
  })
  assert.equal(legacy.pairing.ready, true)
  assert.equal(JSON.stringify(legacy).includes('token'), false)
})

test('audit writes only the allowed fields and rotates at 1 MiB', (t) => {
  const dir = tempDir(t)
  const path = join(dir, 'audit.jsonl')
  const audit = createAudit({ path })
  audit.record({
    source: 'phone',
    principal: 'owner',
    deviceId: 'dev_1',
    reqId: 'r_1',
    sessionId: 's_1',
    kind: 'approval',
    outcome: 'allowed-once',
    args: { command: 'do not write me' },
    code: 'do not write me either',
  })
  const first = JSON.parse(readFileSync(path, 'utf8').trim())
  assert.equal(first.source, 'phone')
  assert.equal(first.principal, 'owner')
  assert.equal(first.kind, 'approval')
  assert.equal(first.outcome, 'allowed-once')
  assert.equal(first.args, undefined)
  assert.equal(first.code, undefined)
  assert.equal(statSync(path).mode & 0o777, 0o600)

  writeFileSync(path, 'x'.repeat(1024 * 1024 + 1))
  audit.record({ source: 'app', kind: 'setup', outcome: 'applied' })
  assert.equal(existsSync(`${path}.1`), true)
  const lines = readFileSync(path, 'utf8').trim().split('\n')
  assert.equal(lines.length, 1)
  assert.equal(JSON.parse(lines[0]).outcome, 'applied')
})

