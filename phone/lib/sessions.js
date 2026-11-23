/** Phone device sessions. Only SHA-256 hashes are ever written to disk. */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DEFAULT_DIR = join(homedir(), '.dsh', 'cue9', 'phone')
const FILE_NAME = 'sessions.json'
const COOKIE_NAME = 'cue9_session'
const COOKIE_MAX_AGE = 31_536_000
const DEFAULT_PAIRING_TTL_MS = 120_000
const MAX_PAIRINGS = 5
const LAST_SEEN_WRITE_MS = 60_000
const HASH_PATTERN = /^[0-9a-f]{64}$/

function hashToken(token) {
  return createHash('sha256').update(String(token), 'utf8').digest('hex')
}

function safeEqualHex(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false
  if (!HASH_PATTERN.test(left) || !HASH_PATTERN.test(right)) return false
  const a = Buffer.from(left, 'hex')
  const b = Buffer.from(right, 'hex')
  if (a.length !== b.length) return false
  try {
    return timingSafeEqual(a, b)
  } catch {
    return false
  }
}

function randomToken() {
  return randomBytes(32).toString('base64url')
}

function randomDeviceId() {
  return `dev_${randomBytes(12).toString('base64url')}`
}

function parseSessionCookie(header) {
  for (const part of String(header ?? '').split(';')) {
    const index = part.indexOf('=')
    if (index <= 0) continue
    if (part.slice(0, index).trim() !== COOKIE_NAME) continue
    try {
      return decodeURIComponent(part.slice(index + 1).trim())
    } catch {
      return undefined
    }
  }
  return undefined
}

function normalize(raw) {
  const pairing = Array.isArray(raw?.pairing)
    ? raw.pairing
      .filter(entry => entry !== null && typeof entry === 'object'
        && HASH_PATTERN.test(String(entry.hash))
        && Number.isFinite(entry.expiresAt))
      .map(entry => ({ hash: String(entry.hash), expiresAt: Number(entry.expiresAt) }))
      .slice(-MAX_PAIRINGS)
    : []
  const devices = Array.isArray(raw?.devices)
    ? raw.devices
      .filter(entry => entry !== null && typeof entry === 'object'
        && typeof entry.id === 'string'
        && HASH_PATTERN.test(String(entry.hash)))
      .map(entry => ({
        id: String(entry.id),
        hash: String(entry.hash),
        createdAt: Number.isFinite(entry.createdAt) ? Number(entry.createdAt) : 0,
        lastSeenAt: Number.isFinite(entry.lastSeenAt) ? Number(entry.lastSeenAt) : 0,
      }))
    : []
  return { pairing, devices }
}

/**
 * Create the phone session store.
 * @param {{ dir?: string, now?: () => number, log?: Function }} [options]
 */
export function createSessions(options = {}) {
  const dir = typeof options.dir === 'string' && options.dir.length > 0 ? options.dir : DEFAULT_DIR
  const now = typeof options.now === 'function' ? options.now : Date.now
  const log = typeof options.log === 'function' ? options.log : console.log
  const file = join(dir, FILE_NAME)

  mkdirSync(dir, { recursive: true, mode: 0o700 })
  try { chmodSync(dir, 0o700) } catch { /* best effort */ }
  try { chmodSync(file, 0o600) } catch { /* missing or unwritable */ }

  function load() {
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8'))
      return normalize(raw)
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        log(`[cue9-sessions] ignoring unreadable session store: ${error?.message ?? error}`)
      }
      return { pairing: [], devices: [] }
    }
  }

  let state = load()

  function persist() {
    const tmp = `${file}.${process.pid}.tmp`
    const data = `${JSON.stringify({ pairing: state.pairing, devices: state.devices }, null, 2)}\n`
    try {
      writeFileSync(tmp, data, { mode: 0o600 })
      renameSync(tmp, file)
      try { chmodSync(file, 0o600) } catch { /* best effort */ }
    } catch (error) {
      try { unlinkSync(tmp) } catch { /* ignore */ }
      throw error
    }
  }

  function prune() {
    const at = now()
    const before = state.pairing.length
    state.pairing = state.pairing.filter(entry => entry.expiresAt > at)
    return state.pairing.length !== before
  }

  function mintPairing(ttlMs = DEFAULT_PAIRING_TTL_MS) {
    prune()
    const ttl = Number.isFinite(ttlMs) && ttlMs > 0 ? ttlMs : DEFAULT_PAIRING_TTL_MS
    const token = randomToken()
    const expiresAt = now() + ttl
    state.pairing = [...state.pairing, { hash: hashToken(token), expiresAt }].slice(-MAX_PAIRINGS)
    persist()
    return { token, expiresAt }
  }

  function consumePairing(token) {
    if (typeof token !== 'string' || token.length === 0) return undefined
    const pruned = prune()
    const hashed = hashToken(token)
    let index = -1
    for (let i = 0; i < state.pairing.length; i += 1) {
      if (safeEqualHex(hashed, state.pairing[i].hash)) index = i
    }
    if (index < 0) {
      if (pruned) persist()
      return undefined
    }

    state.pairing.splice(index, 1)
    const at = now()
    const deviceId = randomDeviceId()
    const sessionToken = randomToken()
    state.devices.push({
      id: deviceId,
      hash: hashToken(sessionToken),
      createdAt: at,
      lastSeenAt: at,
    })
    persist()
    return { deviceId, sessionToken }
  }

  function authenticate(request) {
    const token = parseSessionCookie(request?.headers?.cookie)
    if (token === undefined || token.length === 0) return undefined
    const hashed = hashToken(token)
    let device
    for (const entry of state.devices) {
      if (safeEqualHex(hashed, entry.hash)) device = entry
    }
    if (device === undefined) return undefined

    const at = now()
    const shouldPersist = at - device.lastSeenAt >= LAST_SEEN_WRITE_MS
    device.lastSeenAt = at
    if (shouldPersist) {
      try { persist() } catch (error) {
        log(`[cue9-sessions] could not update last-seen: ${error?.message ?? error}`)
      }
    }
    return { id: device.id, createdAt: device.createdAt, lastSeenAt: device.lastSeenAt }
  }

  function listDevices() {
    return state.devices.map(device => ({
      id: device.id,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
    }))
  }

  function revoke(deviceId) {
    if (typeof deviceId !== 'string' || deviceId.length === 0) return false
    const before = state.devices.length
    state.devices = state.devices.filter(device => device.id !== deviceId)
    if (state.devices.length === before) return false
    persist()
    return true
  }

  function revokeAll() {
    const count = state.devices.length
    state.devices = []
    state.pairing = []
    persist()
    return count
  }

  function sessionCookie(token, secure) {
    const parts = [
      `${COOKIE_NAME}=${encodeURIComponent(String(token))}`,
      'HttpOnly',
      'SameSite=Strict',
      'Path=/',
      `Max-Age=${COOKIE_MAX_AGE}`,
    ]
    if (secure === true) parts.push('Secure')
    return parts.join('; ')
  }

  return {
    mintPairing,
    consumePairing,
    authenticate,
    listDevices,
    revoke,
    revokeAll,
    sessionCookie,
  }
}

export { COOKIE_NAME }
