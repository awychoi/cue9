/**
 * Mac-app authentication for the local app routes.
 *
 * The raw token lives in the app's Keychain. The plugin stores only its
 * SHA-256 in a 0600 JSON file. A local process can read the hash, but cannot
 * authenticate without the raw token.
 */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

const MIN_TOKEN_LENGTH = 32
const MAX_TOKEN_LENGTH = 512
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+$/
const HASH_PATTERN = /^[a-f0-9]{64}$/i

/** A syntactically valid base64url token of the expected size. */
export function isAppToken(value) {
  return typeof value === 'string'
    && value.length >= MIN_TOKEN_LENGTH
    && value.length <= MAX_TOKEN_LENGTH
    && TOKEN_PATTERN.test(value)
}

function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex')
}

function matchesHash(existing, token) {
  if (!isAppToken(token)) return false
  try {
    const left = Buffer.from(existing, 'hex')
    const right = Buffer.from(hashToken(token), 'hex')
    return left.length === right.length && timingSafeEqual(left, right)
  } catch {
    return false
  }
}

function bearerToken(request) {
  const value = request?.headers?.authorization
  if (typeof value !== 'string') return undefined
  const match = /^Bearer\s+(\S+)\s*$/i.exec(value)
  if (match === null) return undefined
  return match[1]
}

/**
 * @param {{ path: string }} options - absolute path to `app-auth.json`.
 */
export function createAppAuth({ path }) {
  function readHash() {
    try {
      const value = JSON.parse(readFileSync(path, 'utf8'))
      const hash = value?.hash
      return typeof hash === 'string' && HASH_PATTERN.test(hash) ? hash.toLowerCase() : undefined
    } catch {
      return undefined
    }
  }

  function writeHash(hash) {
    const dir = dirname(path)
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const temp = join(dir, `.app-auth-${process.pid}-${randomBytes(6).toString('hex')}.tmp`)
    try {
      writeFileSync(temp, `${JSON.stringify({ hash })}\n`, { mode: 0o600 })
      renameSync(temp, path)
      chmodSync(path, 0o600)
    } catch (error) {
      try { unlinkSync(temp) } catch { /* nothing to clean up */ }
      throw error
    }
  }

  function register(token) {
    if (!isAppToken(token)) return 'invalid'
    const nextHash = hashToken(token)
    const existing = readHash()
    if (existing === undefined) {
      writeHash(nextHash)
      return 'created'
    }
    return existing === nextHash ? 'ok' : 'conflict'
  }

  function verify(request) {
    const token = bearerToken(request)
    const existing = readHash()
    if (existing === undefined) return false
    return matchesHash(existing, token)
  }

  /**
   * Replace the stored app hash after proving knowledge of the current token.
   * `register` remains first-install-only; this is the reset/rotation path.
   */
  function rotate(currentToken, nextToken) {
    const existing = readHash()
    if (existing === undefined || !matchesHash(existing, currentToken)) return 'unauthorized'
    if (!isAppToken(nextToken)) return 'invalid'
    writeHash(hashToken(nextToken))
    return 'rotated'
  }

  function hasToken() {
    return readHash() !== undefined
  }

  return { register, verify, rotate, hasToken }
}
