/**
 * Tell cue9-mote to preview attention while this bridge owns a request.
 *
 * The mote is a separate plugin and may be loaded before or after the phone
 * bridge. Do not rely on listener order: holding an id keeps the mote's
 * preview alive, and releasing the last id resumes its live state.
 *
 * This is presentation only. It never carries approval arguments, tokens, or
 * cookies, and every failure is swallowed so a missing mote cannot affect an
 * approval.
 */

const PREVIEW_PATH = '/plugins/cue9/preview'
const LIVE_PATH = '/plugins/cue9/live'
const ACTION_HEADER = 'x-cue9-action'
const TIMEOUT_MS = 2000
const LOG_INTERVAL_MS = 30_000
const LIVE_SIGNATURE = 'live'

function normalizeKind(kind) {
  return kind === 'question' ? 'question' : 'approval'
}

/**
 * @param {{
 *   origin: (() => string | undefined) | string,
 *   log?: Function,
 *   fetchImpl?: Function,
 * }} options
 */
export function createMoteAttention({ origin, log = console.log, fetchImpl } = {}) {
  const held = new Map()
  const doFetch = typeof fetchImpl === 'function'
    ? fetchImpl
    : (typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : undefined)

  let running = false
  let queued = false
  let dirty = false
  let lastSignature = LIVE_SIGNATURE
  let lastLogAt = 0

  function readOrigin() {
    try {
      const value = typeof origin === 'function' ? origin() : origin
      if (typeof value !== 'string' || value.length === 0) return undefined
      return value.replace(/\/+$/, '')
    } catch {
      return undefined
    }
  }

  function logUnexpected(detail) {
    const now = Date.now()
    if (now - lastLogAt < LOG_INTERVAL_MS) return
    lastLogAt = now
    try {
      log?.(`[cue9-mote] attention update failed: ${detail}`)
    } catch {
      /* logging must not throw into the approval path */
    }
  }

  function currentState() {
    if (held.size === 0) {
      return { path: LIVE_PATH, body: undefined, signature: LIVE_SIGNATURE }
    }
    let kind = 'approval'
    for (const value of held.values()) kind = value
    return {
      path: PREVIEW_PATH,
      body: { action: kind },
      signature: `preview:${kind}`,
    }
  }

  /** @returns {Promise<boolean>} whether a request was attempted */
  async function send(state) {
    const base = readOrigin()
    if (base === undefined) return false

    const url = `${base}${state.path}`
    const body = state.body === undefined ? undefined : JSON.stringify(state.body)
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
    timer.unref?.()

    try {
      if (doFetch === undefined) {
        logUnexpected('fetch is unavailable')
        return true
      }
      const response = await doFetch(url, {
        method: 'POST',
        headers: {
          [ACTION_HEADER]: '1',
          'content-type': 'application/json',
        },
        ...(body === undefined ? {} : { body }),
        credentials: 'omit',
        signal: controller.signal,
      })
      const status = Number(response?.status ?? 0)
      /* Drain the tiny mote response so the local keep-alive socket is reused. */
      try { await response?.arrayBuffer?.() } catch { /* status is enough */ }
      if (status === 400) {
        /* The mote is already urgent and refuses previews. That is expected. */
        return true
      }
      if (response?.ok !== true) logUnexpected(`HTTP ${status || 'unknown'}`)
      return true
    } catch (error) {
      if (error?.name !== 'AbortError') {
        logUnexpected(String(error?.message ?? error))
      } else {
        logUnexpected('request timed out')
      }
      return true
    } finally {
      clearTimeout(timer)
    }
  }

  async function drain() {
    if (running) {
      dirty = true
      return
    }
    running = true
    try {
      do {
        dirty = false
        const next = currentState()
        if (next.signature === lastSignature) continue
        const attempted = await send(next)
        if (attempted) lastSignature = next.signature
      } while (dirty)
    } finally {
      running = false
      if (dirty) schedule()
    }
  }

  function schedule() {
    try {
      if (running) {
        dirty = true
        return
      }
      if (queued) return
      queued = true
      queueMicrotask(() => {
        queued = false
        void drain().catch(() => {
          /* drain handles its own errors; this is the last backstop */
        })
      })
    } catch {
      /* never throw into the approval path */
    }
  }

  function hold(id, kind) {
    try {
      if (id === undefined || id === null) return
      const key = String(id)
      /* Re-holding moves the id to the end so the latest kind wins. */
      if (held.has(key)) held.delete(key)
      held.set(key, normalizeKind(kind))
      schedule()
    } catch {
      /* never throw into the approval path */
    }
  }

  function release(id) {
    try {
      if (id === undefined || id === null) return
      if (!held.delete(String(id))) return
      schedule()
    } catch {
      /* never throw into the approval path */
    }
  }

  return { hold, release }
}
