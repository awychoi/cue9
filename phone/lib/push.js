/** Web Push for the phone. Optional: the surface still works without it. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { requestTitle } from './validate.js'

const DEFAULT_DIR = join(homedir(), '.dsh', 'cue9', 'phone')
const SUBJECT = 'https://awychoi.com'
const MAX_SUBSCRIPTIONS = 20

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
}

function readJson(path, fallback) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return fallback }
}

function writePrivate(path, value) {
  ensureDir(dirname(path))
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
}

function validSubscription(subscription) {
  return subscription !== null
    && typeof subscription === 'object'
    && typeof subscription.endpoint === 'string'
    && subscription.endpoint.startsWith('https://')
    && typeof subscription.keys?.p256dh === 'string'
    && typeof subscription.keys?.auth === 'string'
}

/**
 * Lock-screen safe payload. Deliberately excludes command, args, reason,
 * question text, cwd, and session id; the full detail stays in the app.
 */
export function buildPushPayload(request) {
  const approval = request?.kind === 'approval'
  return JSON.stringify({
    title: requestTitle(request?.kind),
    body: approval ? 'Open cue9 to review.' : 'Open cue9 to answer.',
    url: `/#/r/${encodeURIComponent(request?.reqId ?? '')}`,
    tag: request?.reqId,
  })
}

function normalizeEntry(entry) {
  if (entry === null || typeof entry !== 'object') return undefined
  const subscription = entry.subscription ?? entry
  if (!validSubscription(subscription)) return undefined
  return {
    deviceId: typeof entry.deviceId === 'string' && entry.deviceId.length > 0 ? entry.deviceId : 'legacy',
    subscription: {
      endpoint: subscription.endpoint,
      keys: { p256dh: subscription.keys.p256dh, auth: subscription.keys.auth },
      expirationTime: subscription.expirationTime ?? null,
    },
  }
}

function disabledPush() {
  return {
    enabled: false,
    publicKey: undefined,
    hasSubscriptions: () => false,
    subscribe: () => ({ ok: false, error: 'push-not-installed' }),
    removeDevice: () => ({ ok: false, error: 'push-not-installed' }),
    removeAll: () => ({ ok: false, error: 'push-not-installed' }),
    unsubscribe: () => ({ ok: false, error: 'push-not-installed' }),
    test: async () => ({ ok: false, error: 'push-not-installed', sent: 0, failed: 0 }),
    notify: async () => ({ sent: 0, failed: 0, errors: [] }),
  }
}

/**
 * Create the push sender. Resolves disabled when web-push or the phone is absent.
 * `webpush` is an optional test seam so tests never touch the network.
 * @param {{ log?: Function, dir?: string, webpush?: object }} [options]
 */
export async function createPush(options = {}) {
  const log = typeof options.log === 'function' ? options.log : console.log
  const dir = typeof options.dir === 'string' && options.dir.length > 0 ? options.dir : DEFAULT_DIR
  const keysPath = join(dir, 'push-keys.json')
  const subsPath = join(dir, 'push-subscriptions.json')

  let webpush = options.webpush
  if (webpush === undefined) {
    try {
      const module = await import('web-push')
      webpush = module.default ?? module
    } catch {
      return disabledPush()
    }
  }
  if (typeof webpush?.sendNotification !== 'function') return disabledPush()

  let keys = readJson(keysPath, undefined)
  if (keys?.publicKey === undefined || keys?.privateKey === undefined) {
    keys = webpush.generateVAPIDKeys()
    writePrivate(keysPath, keys)
  }
  try {
    webpush.setVapidDetails(SUBJECT, keys.publicKey, keys.privateKey)
  } catch {
    keys = webpush.generateVAPIDKeys()
    writePrivate(keysPath, keys)
    webpush.setVapidDetails(SUBJECT, keys.publicKey, keys.privateKey)
  }

  const rawSubscriptions = readJson(subsPath, [])
  let subscriptions = Array.isArray(rawSubscriptions)
    ? rawSubscriptions.map(normalizeEntry).filter(Boolean).slice(0, MAX_SUBSCRIPTIONS)
    : []

  function persist() {
    writePrivate(subsPath, subscriptions)
  }

  function subscribe(deviceId, subscription) {
    if (typeof deviceId !== 'string' || deviceId.length === 0) {
      return { ok: false, error: 'invalid-device' }
    }
    if (!validSubscription(subscription)) return { ok: false, error: 'invalid-subscription' }
    const entry = {
      deviceId,
      subscription: {
        endpoint: subscription.endpoint,
        keys: { p256dh: subscription.keys.p256dh, auth: subscription.keys.auth },
        expirationTime: subscription.expirationTime ?? null,
      },
    }
    subscriptions = [
      entry,
      ...subscriptions.filter(item => item.subscription.endpoint !== entry.subscription.endpoint),
    ].slice(0, MAX_SUBSCRIPTIONS)
    persist()
    return { ok: true }
  }

  function removeDevice(deviceId) {
    if (typeof deviceId !== 'string' || deviceId.length === 0) return { ok: true, removed: 0 }
    const before = subscriptions.length
    subscriptions = subscriptions.filter(item => item.deviceId !== deviceId)
    const removed = before - subscriptions.length
    if (removed > 0) persist()
    return { ok: true, removed }
  }

  function removeAll() {
    const removed = subscriptions.length
    subscriptions = []
    persist()
    return { ok: true, removed }
  }

  function unsubscribe(endpoint) {
    const before = subscriptions.length
    subscriptions = subscriptions.filter(item => item.subscription.endpoint !== endpoint)
    if (subscriptions.length !== before) persist()
    return { ok: true }
  }

  /**
   * Push to a snapshot of subscriptions. Non-404/410 errors are kept and
   * reported without logging endpoints or payloads.
   * @returns {Promise<{sent:number, failed:number, errors:{status:number}[]}>}
   */
  async function send(entries, payload) {
    const list = Array.isArray(entries) ? entries.slice() : []
    if (list.length === 0) return { sent: 0, failed: 0, errors: [] }

    const expired = new Set()
    const rejected = []
    let sent = 0

    await Promise.allSettled(list.map(async (entry) => {
      try {
        await webpush.sendNotification(entry.subscription, payload, { TTL: 120 })
        sent += 1
      } catch (error) {
        const status = Number(error?.statusCode ?? error?.status)
        if (status === 404 || status === 410) {
          expired.add(entry.subscription.endpoint)
          return
        }
        rejected.push({ status: Number.isFinite(status) ? status : 0 })
      }
    }))

    const failed = list.length - sent

    if (expired.size > 0) {
      subscriptions = subscriptions.filter(item => !expired.has(item.subscription.endpoint))
      try {
        persist()
      } catch {
        log('[cue9-phone] could not save push subscription cleanup')
      }
      log(`[cue9-phone] dropped ${expired.size} expired push subscription(s)`)
    }

    if (rejected.length > 0) {
      const statuses = [...new Set(rejected.map(item => item.status > 0 ? String(item.status) : 'unknown'))]
      log(`[cue9-phone] push rejected (${statuses.join(', ')}) for ${rejected.length} subscription(s); kept`)
    }

    return { sent, failed, errors: rejected }
  }

  async function test() {
    if (subscriptions.length === 0) {
      return { ok: false, error: 'no-subscriptions', sent: 0, failed: 0 }
    }
    const payload = JSON.stringify({
      title: 'cue9 is connected',
      body: 'Approvals and questions will appear here.',
      url: '/',
      tag: 'cue9-test',
    })
    const result = await send([...subscriptions], payload)
    if (result.sent > 0) {
      return { ok: true, sent: result.sent, failed: result.failed }
    }
    return { ok: false, error: 'push-rejected', sent: 0, failed: result.failed }
  }

  async function notify(request) {
    if (subscriptions.length === 0) return { sent: 0, failed: 0, errors: [] }
    return send([...subscriptions], buildPushPayload(request))
  }

  return {
    enabled: true,
    publicKey: keys.publicKey,
    hasSubscriptions: () => subscriptions.length > 0,
    subscribe,
    removeDevice,
    removeAll,
    unsubscribe,
    test,
    notify,
  }
}
