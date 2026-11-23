import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { COOKIE_NAME, createSessions } from '../lib/sessions.js'

function tempDir() {
  return mkdtempSync(join(tmpdir(), 'cue9-sessions-'))
}

function cookieFor(token) {
  return `${COOKIE_NAME}=${encodeURIComponent(token)}`
}

test('mint, consume once, and store only hashes', () => {
  const dir = tempDir()
  try {
    let clock = 1_000_000
    const sessions = createSessions({ dir, now: () => clock, log: () => {} })
    const { token, expiresAt } = sessions.mintPairing(60_000)
    assert.equal(typeof token, 'string')
    assert.ok(token.length >= 32)
    assert.equal(expiresAt, clock + 60_000)

    const result = sessions.consumePairing(token)
    assert.ok(result?.deviceId.startsWith('dev_'))
    assert.equal(typeof result?.sessionToken, 'string')
    assert.equal(sessions.consumePairing(token), undefined)

    const raw = readFileSync(join(dir, 'sessions.json'), 'utf8')
    assert.equal(raw.includes(token), false)
    assert.equal(raw.includes(result.sessionToken), false)
    assert.match(raw, /"hash": "[0-9a-f]{64}"/)
    assert.match(raw, /"devices"/)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('expired pairing cannot be consumed', () => {
  const dir = tempDir()
  try {
    let clock = 2_000
    const sessions = createSessions({ dir, now: () => clock, log: () => {} })
    const { token } = sessions.mintPairing(1_000)
    clock += 1_001
    assert.equal(sessions.consumePairing(token), undefined)
    assert.deepEqual(sessions.listDevices(), [])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('session cookie authenticates and updates last seen with throttled writes', () => {
  const dir = tempDir()
  try {
    let clock = 10_000
    const sessions = createSessions({ dir, now: () => clock, log: () => {} })
    const { token } = sessions.mintPairing()
    const pair = sessions.consumePairing(token)
    const request = { headers: { cookie: cookieFor(pair.sessionToken) } }

    const device = sessions.authenticate(request)
    assert.equal(device?.id, pair.deviceId)
    assert.equal(device?.lastSeenAt, clock)
    assert.equal(sessions.authenticate({ headers: {} }), undefined)
    assert.equal(sessions.authenticate({ headers: { cookie: `${COOKIE_NAME}=wrong` } }), undefined)
    assert.equal(sessions.authenticate({ headers: { cookie: cookieFor('wrong') } }), undefined)

    const firstSeen = sessions.listDevices()[0].lastSeenAt
    clock += 1_000
    sessions.authenticate(request)
    assert.equal(sessions.listDevices()[0].lastSeenAt, clock)
    assert.equal(firstSeen, 10_000)

    clock += 61_000
    sessions.authenticate(request)
    assert.equal(sessions.listDevices()[0].lastSeenAt, clock)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('revoke and revokeAll invalidate sessions', () => {
  const dir = tempDir()
  try {
    let clock = 20_000
    const sessions = createSessions({ dir, now: () => clock, log: () => {} })
    const first = sessions.consumePairing(sessions.mintPairing().token)
    const second = sessions.consumePairing(sessions.mintPairing().token)
    const firstCookie = { headers: { cookie: cookieFor(first.sessionToken) } }
    const secondCookie = { headers: { cookie: cookieFor(second.sessionToken) } }

    assert.equal(sessions.listDevices().length, 2)
    assert.equal(sessions.revoke(first.deviceId), true)
    assert.equal(sessions.authenticate(firstCookie), undefined)
    assert.ok(sessions.authenticate(secondCookie))

    assert.equal(sessions.revokeAll(), 1)
    assert.equal(sessions.authenticate(secondCookie), undefined)
    assert.deepEqual(sessions.listDevices(), [])
    assert.equal(sessions.revoke('dev_missing'), false)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('session cookie is HttpOnly, Strict, and optionally Secure', () => {
  const dir = tempDir()
  try {
    const sessions = createSessions({ dir, now: () => 1, log: () => {} })
    const plain = sessions.sessionCookie('abc', false)
    assert.match(plain, new RegExp(`^${COOKIE_NAME}=abc;`))
    assert.match(plain, /HttpOnly/)
    assert.match(plain, /SameSite=Strict/)
    assert.match(plain, /Path=\//)
    assert.match(plain, /Max-Age=31536000/)
    assert.equal(plain.includes('Secure'), false)
    assert.match(sessions.sessionCookie('abc', true), /; Secure$/)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('missing and corrupt stores fail closed without throwing', () => {
  const dir = tempDir()
  try {
    const fresh = createSessions({ dir, now: () => 1, log: () => {} })
    assert.deepEqual(fresh.listDevices(), [])

    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'sessions.json'), '{not json', { mode: 0o600 })
    const corrupt = createSessions({ dir, now: () => 1, log: () => {} })
    assert.deepEqual(corrupt.listDevices(), [])
    assert.equal(corrupt.authenticate({ headers: { cookie: `${COOKIE_NAME}=none` } }), undefined)

    const token = corrupt.mintPairing().token
    assert.ok(corrupt.consumePairing(token)?.sessionToken)
    assert.equal(JSON.parse(readFileSync(join(dir, 'sessions.json'), 'utf8')).devices.length, 1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
