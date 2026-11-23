/** Configuration paths and LAN discovery for the cue9 phone bridge. */
import { mkdirSync, readFileSync } from 'node:fs'
import { homedir, networkInterfaces } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = homedir()
const PHONE_DIR = join(HOME, '.dsh', 'cue9', 'phone')
const CONFIG_PATH = join(HOME, '.dsh', 'cue9', 'phone.json')
const PUBLIC_DIR = fileURLToPath(new URL('../public/', import.meta.url))
const SESSIONS_DIR = PHONE_DIR
const APP_AUTH_PATH = join(PHONE_DIR, 'app-auth.json')
const AUDIT_PATH = join(PHONE_DIR, 'audit.jsonl')

function ensurePrivateDir(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 })
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return {}
  }
}

const VIRTUAL_PREFIXES = ['utun', 'awdl', 'llw', 'bridge', 'vmnet', 'lo']

function octets(address) {
  if (typeof address !== 'string') return undefined
  const parts = address.split('.')
  if (parts.length !== 4) return undefined
  const values = parts.map(part => Number(part))
  if (values.some(value => !Number.isInteger(value) || value < 0 || value > 255)) return undefined
  return values
}

function isPrivateIPv4(address) {
  const parts = octets(address)
  if (parts === undefined) return false
  const [a, b] = parts
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
}

function isCgnatIPv4(address) {
  const parts = octets(address)
  return parts !== undefined && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127
}

function isLinkLocalIPv4(address) {
  const parts = octets(address)
  return parts !== undefined && parts[0] === 169 && parts[1] === 254
}

/**
 * Pick a usable LAN IPv4 address from `os.networkInterfaces()`.
 *
 * Real Ethernet/Wi-Fi interfaces win over virtual interfaces, and private
 * addresses win over public ones. CGNAT and link-local addresses are never
 * advertised as a LAN address.
 *
 * @param {object} interfaces
 * @returns {string | undefined}
 */
export function pickLanAddress(interfaces) {
  const candidates = []
  for (const [name, entries] of Object.entries(interfaces ?? {})) {
    const lower = name.toLowerCase()
    if (VIRTUAL_PREFIXES.some(prefix => lower.startsWith(prefix))) continue
    for (const entry of entries ?? []) {
      if (entry === null || typeof entry !== 'object' || entry.internal === true) continue
      if (entry.family !== 'IPv4' && entry.family !== 4) continue
      const address = String(entry.address ?? '')
      if (octets(address) === undefined) continue
      if (isCgnatIPv4(address) || isLinkLocalIPv4(address)) continue
      const preferred = /^en[0-3]$/.test(lower)
      candidates.push({
        name: lower,
        address,
        private: isPrivateIPv4(address),
        priority: preferred ? Number(lower.slice(2)) : Number.POSITIVE_INFINITY,
      })
    }
  }

  candidates.sort((left, right) => left.priority - right.priority)
  return (candidates.find(candidate => candidate.private)
    ?? candidates.find(candidate => candidate.priority !== Number.POSITIVE_INFINITY)
    ?? candidates[0])?.address
}

/** First usable LAN IPv4 address, for the printed LAN pairing URL. */
export function lanAddress() {
  return pickLanAddress(networkInterfaces())
}

/** Load the optional config and resolve the asset/session paths. */
export function loadConfig() {
  ensurePrivateDir(PHONE_DIR)
  const raw = readJson(CONFIG_PATH)
  const port = Number.isInteger(raw.port) && raw.port > 0 ? raw.port : 8791
  return {
    port,
    host: typeof raw.host === 'string' && raw.host.length > 0 ? raw.host : '127.0.0.1',
    publicOrigin: typeof raw.publicOrigin === 'string' ? raw.publicOrigin : undefined,
    lan: raw.lan && typeof raw.lan === 'object' ? raw.lan : undefined,
    allowDev: raw.allowDev === true,
    ownerLogin: typeof raw.ownerLogin === 'string' ? raw.ownerLogin : undefined,
    ttlMs: Number.isInteger(raw.ttlMs) && raw.ttlMs > 0 ? raw.ttlMs : undefined,
    configPath: CONFIG_PATH,
    publicDir: PUBLIC_DIR,
    sessionsDir: PHONE_DIR,
    appAuthPath: APP_AUTH_PATH,
    auditPath: AUDIT_PATH,
  }
}

export { PHONE_DIR, CONFIG_PATH, PUBLIC_DIR, APP_AUTH_PATH, AUDIT_PATH, SESSIONS_DIR }
