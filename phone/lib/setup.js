/** One-time phone setup: Tailscale name, certificate, LAN listener, Serve. */
import { execFile as execFileCallback } from 'node:child_process'
import { X509Certificate } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { CONFIG_PATH, PHONE_DIR, lanAddress } from './config.js'

const execFile = promisify(execFileCallback)
const TLS_DIR = join(PHONE_DIR, 'tls')
const CERT_FILE = join(TLS_DIR, 'cert.pem')
const KEY_FILE = join(TLS_DIR, 'key.pem')
const SERVE_PORT = 8443

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return {} }
}

/**
 * Read the Mac's Tailscale state without changing anything.
 * @returns {Promise<{running: boolean, dnsName?: string, error?: string}>}
 */
export async function tailscaleState() {
  try {
    const { stdout } = await execFile('tailscale', ['status', '--json'], {
      timeout: 3000,
      maxBuffer: 8 * 1024 * 1024,
    })
    const status = JSON.parse(stdout)
    const dnsName = String(status?.Self?.DNSName ?? '').replace(/\.$/, '')
    const online = status?.Self?.Online === true
    if (dnsName === '') return { running: false, error: 'Tailscale has no DNS name yet.' }
    const peers = Object.values(status?.Peer ?? {})
    const ios = peers.filter(peer => String(peer?.OS ?? '').toLowerCase() === 'ios')
    return {
      running: true,
      online,
      dnsName,
      iosDevices: ios.length,
      iosOnline: ios.filter(peer => peer?.Online === true).length,
      ...(online ? {} : { error: 'Tailscale is open, but this Mac is offline. Click Connect in Tailscale.' }),
    }
  } catch (error) {
    return { running: false, error: 'Tailscale is not running on this Mac.' }
  }
}

async function serveActive(dnsName) {
  try {
    const { stdout } = await execFile('tailscale', ['serve', 'status'], { timeout: 2000 })
    return String(stdout).includes(`https://${dnsName}:${SERVE_PORT}`)
  } catch {
    return false
  }
}

const RENEW_SOON_DAYS = 14

/**
 * Read the certificate's public expiry metadata. The private key is checked
 * for existence only; its contents are never read or returned.
 *
 * @param {string} [certFile]
 * @param {string} [keyFile]
 * @param {number} [now]
 * @returns {{ready: boolean, expiresAt: string|null, daysRemaining: number|null, renewSoon: boolean}}
 */
export function certificateInfo(certFile = CERT_FILE, keyFile = KEY_FILE, now = Date.now()) {
  const ready = existsSync(certFile) && existsSync(keyFile)
  if (!ready) {
    return { ready: false, expiresAt: null, daysRemaining: null, renewSoon: true }
  }
  try {
    const certificate = new X509Certificate(readFileSync(certFile))
    const expires = new Date(certificate.validTo)
    if (Number.isNaN(expires.getTime())) {
      return { ready: true, expiresAt: null, daysRemaining: null, renewSoon: true }
    }
    const daysRemaining = Math.floor((expires.getTime() - now) / 86_400_000)
    return {
      ready: true,
      expiresAt: expires.toISOString(),
      daysRemaining,
      renewSoon: daysRemaining < RENEW_SOON_DAYS,
    }
  } catch {
    return { ready: true, expiresAt: null, daysRemaining: null, renewSoon: true }
  }
}

/**
 * Snapshot for the app's setup wizard. Never returns a pairing token.
 * `paths` and `deps` are test seams; production callers omit them.
 *
 * @param {{
 *   config: object,
 *   phone?: object,
 *   push?: object,
 *   sessions?: object,
 *   paths?: {certFile?: string, keyFile?: string},
 *   deps?: {tailscale?: object, serve?: boolean, lan?: string, https?: object},
 * }} options
 */
export async function setupStatus({ config, phone, push, sessions, paths = {}, deps = {} }) {
  const tailscale = deps.tailscale ?? await tailscaleState()
  const dnsName = tailscale.dnsName
  const lan = deps.lan ?? lanAddress()
  const serve = deps.serve
    ?? (dnsName === undefined ? false : await serveActive(dnsName))
  const publicOrigin = config.publicOrigin
    ?? (dnsName === undefined ? undefined : `https://${dnsName}:${SERVE_PORT}`)
  const https = deps.https ?? certificateInfo(paths.certFile, paths.keyFile)
  const pairingReady = config.publicOrigin !== undefined && serve && https.ready === true
  const devices = typeof sessions?.listDevices === 'function' ? sessions.listDevices() : []
  return {
    ok: true,
    tailscale: {
      ...tailscale,
      adminUrl: 'https://login.tailscale.com/admin/dns',
      appPath: '/Applications/Tailscale.app',
    },
    https: {
      ready: https.ready === true,
      certFile: https.certFile ?? paths.certFile ?? CERT_FILE,
      expiresAt: typeof https.expiresAt === 'string' ? https.expiresAt : null,
      daysRemaining: Number.isInteger(https.daysRemaining) ? https.daysRemaining : null,
      renewSoon: https.renewSoon === true,
    },
    serve: {
      active: serve,
      port: SERVE_PORT,
      url: dnsName === undefined ? undefined : `https://${dnsName}:${SERVE_PORT}`,
    },
    localDns: {
      name: dnsName,
      address: lan,
    },
    config: {
      publicOrigin: config.publicOrigin,
      lan: config.lan,
      port: config.port,
    },
    phone: {
      paired: devices.length > 0,
      devices,
      clients: phone?.clients.size ?? 0,
      lastSeenAt: phone?.lastSeenAt ?? 0,
      push: push?.hasSubscriptions() === true,
    },
    pairing: {
      ready: pairingReady,
      origin: publicOrigin,
    },
    canApply: tailscale.running && tailscale.online === true && dnsName !== undefined && lan !== undefined,
  }
}

/**
 * Issue the certificate, write the LAN config and start Tailscale Serve.
 * Mutates the shared config only after every step succeeds.
 * @param {{config: object, log?: Function}} options
 */
export async function applySetup({ config, log = console.log }) {
  const tailscale = await tailscaleState()
  if (!tailscale.running || tailscale.online !== true || tailscale.dnsName === undefined) {
    throw new Error('This Mac is not connected to Tailscale. Open Tailscale and click Connect first.')
  }
  const lan = lanAddress()
  if (lan === undefined) throw new Error('This Mac has no LAN address. Connect it to Wi-Fi or Ethernet.')
  const dnsName = tailscale.dnsName

  mkdirSync(TLS_DIR, { recursive: true, mode: 0o700 })
  log(`[cue9-phone] requesting certificate for ${dnsName}`)
  try {
    await execFile('tailscale', [
      'cert',
      `--cert-file=${CERT_FILE}`,
      `--key-file=${KEY_FILE}`,
      dnsName,
    ], { timeout: 60_000 })
  } catch (error) {
    const detail = String(error?.stderr ?? '').trim()
    throw new Error(detail.length > 0
      ? detail
      : 'Tailscale could not issue a certificate. Turn on HTTPS Certificates in the Tailscale admin DNS page, then try again.')
  }

  const current = readJson(CONFIG_PATH)
  const next = {
    ...current,
    port: Number.isInteger(config.port) ? config.port : 8791,
    publicOrigin: `https://${dnsName}:${SERVE_PORT}`,
    lan: { host: lan, port: SERVE_PORT, certFile: CERT_FILE, keyFile: KEY_FILE },
  }
  mkdirSync(join(homedir(), '.dsh', 'cue9'), { recursive: true, mode: 0o700 })
  writeFileSync(CONFIG_PATH, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 })

  log(`[cue9-phone] exposing only the phone port on ${dnsName}:${SERVE_PORT}`)
  try {
    await execFile('tailscale', [
      'serve',
      '--bg',
      `--https=${SERVE_PORT}`,
      `http://127.0.0.1:${next.port}`,
    ], { timeout: 15_000 })
  } catch (error) {
    const detail = String(error?.stderr ?? '').trim()
    throw new Error(detail.length > 0
      ? detail
      : 'Tailscale Serve could not start. Check that this Mac is connected to Tailscale.')
  }

  config.publicOrigin = next.publicOrigin
  config.lan = next.lan
  return next
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isEmptyConfig(value) {
  if (value === undefined || value === null) return true
  if (typeof value === 'string') return value.length === 0
  if (Array.isArray(value)) return value.length === 0
  if (isRecord(value)) return Object.keys(value).length === 0
  return false
}

function normalizeProxy(value) {
  return typeof value === 'string' ? value.replace(/\/+$/, '') : undefined
}

/**
 * Decide whether Serve contains only the cue9 route. This is pure so the reset
 * can be tested without touching the real Tailscale configuration.
 *
 * @param {unknown} status - parsed `tailscale serve status --json`
 * @param {number} port - local phone HTTP port
 * @returns {{mode: 'empty'|'ours'|'other', leftover?: string}}
 */
export function classifyServeStatus(status, port = 8791) {
  if (!isRecord(status)) {
    return { mode: 'other', leftover: 'other Tailscale Serve configuration' }
  }

  const localPort = Number.isInteger(Number(port)) && Number(port) > 0 ? Number(port) : 8791
  const web = isRecord(status.Web) ? status.Web : undefined
  const tcp = isRecord(status.TCP) ? status.TCP : undefined
  const webKeys = web === undefined ? [] : Object.keys(web)
  const tcpKeys = tcp === undefined ? [] : Object.keys(tcp)
  const web8443 = webKeys.find(key => key.endsWith(`:${SERVE_PORT}`))
  const leftover = web8443
    ?? (tcpKeys.includes(String(SERVE_PORT)) ? `TCP ${SERVE_PORT}` : 'other Tailscale Serve configuration')

  let otherConfig = false
  for (const [key, value] of Object.entries(status)) {
    if (key === 'TCP' || key === 'Web') continue
    if (key === 'AllowFunnel') {
      if (isRecord(value)) {
        if (Object.values(value).some(Boolean)) otherConfig = true
      } else if (value !== undefined && value !== null) {
        otherConfig = true
      }
      continue
    }
    if (!isEmptyConfig(value)) otherConfig = true
  }

  const webOurs = webKeys.length === 1
    && webKeys[0].endsWith(`:${SERVE_PORT}`)
    && isRecord(web?.[webKeys[0]]?.Handlers)
    && Object.keys(web[webKeys[0]].Handlers).length === 1
    && Object.hasOwn(web[webKeys[0]].Handlers, '/')
    && normalizeProxy(web[webKeys[0]].Handlers['/']?.Proxy) === `http://127.0.0.1:${localPort}`

  const tcpOurs = tcpKeys.length === 0
    || (tcpKeys.length === 1
      && tcpKeys[0] === String(SERVE_PORT)
      && isRecord(tcp?.[tcpKeys[0]])
      && tcp[tcpKeys[0]].HTTPS === true
      && Object.keys(tcp[tcpKeys[0]]).every(key => key === 'HTTPS'))

  if (otherConfig || !webOurs || !tcpOurs) {
    if (webKeys.length === 0 && tcpKeys.length === 0 && !otherConfig) return { mode: 'empty' }
    return { mode: 'other', leftover }
  }
  if (webKeys.length === 0 && tcpKeys.length === 0) return { mode: 'empty' }
  return { mode: 'ours' }
}

function removeFile(path) {
  try {
    unlinkSync(path)
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }
}

function removeEmptyDir(path) {
  try {
    rmdirSync(path)
  } catch (error) {
    if (error?.code !== 'ENOENT' && error?.code !== 'ENOTEMPTY' && error?.code !== 'EEXIST') throw error
  }
}

/**
 * Undo the phone setup without touching the user's Tailscale login/device.
 * App auth is intentionally preserved; only phone devices, pairing links,
 * notifications, config, certificate and our Serve route are removed.
 *
 * `paths` and `runCommand` are test seams. Production calls use the fixed
 * ~/.dsh paths and the real tailscale binary.
 *
 * @param {{
 *   config: object,
 *   phone?: object,
 *   push?: object,
 *   sessions?: object,
 *   log?: Function,
 *   paths?: {configPath?: string, tlsDir?: string, certFile?: string, keyFile?: string},
 *   runCommand?: Function,
 * }} options
 */
export async function resetSetup({
  config,
  phone,
  push,
  sessions,
  log = console.log,
  paths = {},
  runCommand = execFile,
} = {}) {
  const port = Number.isInteger(config?.port) && config.port > 0 ? config.port : 8791
  const configPath = paths.configPath ?? CONFIG_PATH
  const tlsDir = paths.tlsDir ?? TLS_DIR
  const certFile = paths.certFile ?? join(tlsDir, 'cert.pem')
  const keyFile = paths.keyFile ?? join(tlsDir, 'key.pem')

  const revoked = Number(sessions?.revokeAll?.() ?? 0)
  await push?.removeAll?.()
  await phone?.stop?.()

  config.publicOrigin = undefined
  config.lan = undefined

  removeFile(configPath)
  removeFile(certFile)
  removeFile(keyFile)
  removeEmptyDir(tlsDir)

  let serveReset = false
  let warning
  try {
    const { stdout } = await runCommand('tailscale', ['serve', 'status', '--json'], {
      timeout: 3000,
      maxBuffer: 8 * 1024 * 1024,
    })
    let status
    try {
      status = JSON.parse(String(stdout ?? '').trim() || '{}')
    } catch {
      throw new Error('invalid Tailscale Serve status')
    }
    const plan = classifyServeStatus(status, port)
    if (plan.mode === 'empty') {
      serveReset = true
    } else if (plan.mode === 'ours') {
      try {
        await runCommand('tailscale', ['serve', 'reset'], {
          timeout: 10_000,
          maxBuffer: 8 * 1024 * 1024,
        })
        serveReset = true
      } catch {
        warning = `Tailscale Serve could not be reset (${plan.leftover} is still configured); run tailscale serve reset manually.`
      }
    } else {
      warning = `Tailscale Serve still has other configuration (${plan.leftover}); cue9 left it untouched.`
    }
  } catch {
    warning = 'Could not read Tailscale Serve status; cue9 left Serve untouched.'
  }

  if (warning !== undefined) {
    try { log(`[cue9-phone] setup reset: ${warning}`) } catch { /* logging is not critical */ }
  }

  return {
    ok: true,
    revoked: Number.isFinite(revoked) ? revoked : 0,
    serveReset,
    ...(warning === undefined ? {} : { warning }),
  }
}
