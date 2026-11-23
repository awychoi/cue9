/**
 * Host half of the cue9 phone bridge.
 *
 * Co-displays every approval/question in DSH's own UI and on the phone. DSH's
 * card is opened immediately; the first answer (DSH or phone) wins, and a phone
 * answer cancels DSH's card by aborting the projected request signal. No handoff
 * / "Show in DSH" step is needed.
 *
 * Security:
 * - App routes use a Keychain-held bearer token, stored here as a hash.
 * - Every answer and ack is bound to the exact session and call.
 * - Pairing tokens are minted by the sessions service and never logged.
 */
import { isLoopback, isSubagentSession, jsonSize, MAX_APPROVAL_ARGS_BYTES, MAX_BODY_BYTES, commandOf, displayReasonOf, cloneApprovalArguments } from './lib/validate.js'
import { RequestStore } from './lib/store.js'
import { loadConfig, PHONE_DIR } from './lib/config.js'
import { createSessions } from './lib/sessions.js'
import { createPhoneServer } from './lib/phone-server.js'
import { createPush } from './lib/push.js'
import { createPower } from './lib/power.js'
import { createAppAuth } from './lib/app-auth.js'
import { createAudit } from './lib/audit.js'
import { createMoteAttention } from './lib/mote-attention.js'
import { applySetup, resetSetup, setupStatus } from './lib/setup.js'

const PHONE_PREFIX = '/plugins/cue9-phone'
const ARG_TTL_MS = 10 * 60 * 1000
const PAIRING_TTL_MS = 2 * 60 * 1000

function sendJson(res, status, value) {
  const body = JSON.stringify(value)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(body)
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new Error('body-too-large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      } catch {
        reject(new Error('invalid-json'))
      }
    })
    req.on('error', reject)
  })
}

/** Recursively drop anything whose field name advertises a token. */
function stripSecretFields(value, depth = 0) {
  if (value === null || typeof value !== 'object' || depth > 4) return value
  if (Array.isArray(value)) return value.map(entry => stripSecretFields(entry, depth + 1))
  const out = {}
  for (const [key, entry] of Object.entries(value)) {
    if (typeof key === 'string' && key.toLowerCase().includes('token')) continue
    out[key] = stripSecretFields(entry, depth + 1)
  }
  return out
}

/**
 * Strip any raw pairing token from a setup status. The sessions service owns
 * pairing; setup statuses are descriptive only.
 */
export function safeSetupStatus(status) {
  const source = status ?? {}
  const pairing = source.pairing ?? {}
  const origin = typeof pairing.origin === 'string'
    ? pairing.origin
    : (typeof source.config?.publicOrigin === 'string' ? source.config.publicOrigin : undefined)
  const ready = pairing.ready === true || pairing.public === true
  const safe = stripSecretFields({ ...source, pairing: { ready } })
  if (origin !== undefined) safe.pairing.origin = origin
  return safe
}

function disabledPush() {
  return {
    enabled: false,
    publicKey: undefined,
    hasSubscriptions: () => false,
    subscribe: () => ({ ok: false, error: 'push-not-configured' }),
    removeDevice: () => {},
    removeAll: () => {},
    test: async () => ({ ok: false, error: 'no-subscriptions' }),
    notify: async () => {},
  }
}

/**
 * Race a co-displayed request. `next()` is called exactly once; the DSH card is
 * already open. The phone wins only when its store promise resolves; a phone
 * answer aborts the DSH request signal to close that card. DSH-first
 * settlement closes the phone surface without resolving its promise.
 */
export async function runCoDisplay({ store, pending, next, controller }) {
  let dshPromise
  try {
    dshPromise = Promise.resolve(next())
  } catch (error) {
    store.abortFromDsh(pending.reqId, error)
    throw error
  }

  const dsh = dshPromise.then(
    value => ({ kind: 'dsh', value }),
    error => ({ kind: 'error', error }),
  )
  const phone = pending.promise.then(
    value => ({ kind: 'phone', value }),
    error => ({ kind: 'error', error }),
  )

  const winner = await Promise.race([phone, dsh])
  if (winner.kind === 'phone') {
    controller.abort()
    // next() is expected to reject after the card is cancelled; ignore it.
    void dshPromise.catch(() => {})
    return winner.value
  }
  if (winner.kind === 'dsh') {
    store.settleFromDsh(pending.reqId, winner.value, 'dsh')
    return winner.value
  }

  store.abortFromDsh(pending.reqId, winner.error)
  throw winner.error
}

/** Host plugin body. */
export async function apply(ctx) {
  const config = loadConfig()
  const store = new RequestStore({ ttlMs: config.ttlMs })
  const sessions = createSessions({ dir: config.sessionsDir ?? PHONE_DIR, log: console.log })
  const appAuth = createAppAuth({ path: config.appAuthPath ?? `${PHONE_DIR}/app-auth.json` })
  const audit = createAudit({ path: config.auditPath ?? `${PHONE_DIR}/audit.jsonl` })
  const moteAttention = createMoteAttention({
    origin: () => {
      try { return ctx.get('webServer')?.getOrigin() } catch { return undefined }
    },
    log: console.log,
  })
  const args = new Map()
  let activeApprovals = 0
  let activeQuestions = 0
  const power = createPower({
    ctx,
    waiting: () => activeApprovals + activeQuestions,
    log: console.log,
  })

  let push
  try {
    push = await createPush({ log: console.log })
  } catch (error) {
    console.error('[cue9-phone] Web Push failed to initialize:', error?.message ?? error)
    push = disabledPush()
  }
  if (!push.enabled) console.log('[cue9-phone] Web Push unavailable; the phone must be open to receive requests.')

  let phone
  try {
    phone = createPhoneServer({ config, store, sessions, push, audit, log: console.log })
  } catch (error) {
    console.error('[cue9-phone] phone surface unavailable:', error?.message ?? error)
  }

  const phoneAlive = () => (phone?.clients.size ?? 0) > 0 || push.hasSubscriptions() === true
  const hasSurface = () => phoneAlive()

  store.on('request', request => {
    phone?.broadcast('request', request)
    // A foreground phone acknowledges immediately; a suspended phone does not.
    // Wait one beat before pushing so an open app is not notified twice.
    const timer = setTimeout(() => {
      if (!store.isPending(request.reqId)) return
      if (store.ackedBy(request.reqId, 'phone')) return
      void push.notify(request)
    }, 1500)
    timer.unref?.()
  })
  store.on('resolved', result => {
    phone?.broadcast('resolved', result)
  })

  function remember(exec) {
    const callId = exec?.callId
    if (typeof callId !== 'string' || callId.length === 0) return
    if (exec.arguments === undefined) return
    const argumentsCopy = cloneApprovalArguments(exec.arguments)
    if (argumentsCopy === undefined) return
    args.set(callId, {
      name: exec.name,
      arguments: argumentsCopy,
      cwd: exec.agent?.session?.header?.cwd,
      at: Date.now(),
    })
    if (args.size > 200) {
      const oldest = [...args.entries()].sort((a, b) => a[1].at - b[1].at)[0]
      if (oldest !== undefined) args.delete(oldest[0])
    }
  }

  function cached(callId) {
    const entry = args.get(callId)
    if (entry === undefined) return undefined
    if (Date.now() - entry.at > ARG_TTL_MS) {
      args.delete(callId)
      return undefined
    }
    return entry
  }

  ctx.on('tools/pre-execute', (exec, next) => {
    remember(exec)
    return next()
  }, { prepend: true })

  ctx.on('tools/result', (exec) => {
    if (typeof exec?.callId === 'string') args.delete(exec.callId)
  })

  ctx.on('approval/request', async (req, next) => {
    activeApprovals += 1
    try {
      if (isSubagentSession(req?.agent?.session)) return next()
      const callId = req?.callId
      if (typeof callId !== 'string' || callId.length === 0) return next()
      const entry = cached(callId)
      if (entry === undefined || jsonSize(entry.arguments) > MAX_APPROVAL_ARGS_BYTES) return next()
      if (!hasSurface()) return next()

      const originalSignal = req.signal
      const controller = new AbortController()
      const forwardAbort = () => controller.abort()
      if (originalSignal !== undefined) {
        if (originalSignal.aborted) controller.abort()
        else originalSignal.addEventListener('abort', forwardAbort, { once: true })
      }

      const pending = store.create({
        kind: 'approval',
        sessionId: req.agent?.session?.id,
        callId,
        toolName: req.toolName,
        args: entry.arguments,
        command: commandOf(entry.arguments),
        cwd: entry.cwd ?? req.agent?.session?.header?.cwd,
        reason: req.reason,
        displayReason: displayReasonOf(req),
        coDisplay: true,
        signal: originalSignal,
      })

      try {
        moteAttention.hold(pending.reqId, 'approval')
        try {
          // The gateway projects req.signal onto the DSH card. Aborting our
          // controller from the phone winner closes that card.
          req.signal = controller.signal
          return await runCoDisplay({ store, pending, next, controller })
        } finally {
          moteAttention.release(pending.reqId)
        }
      } finally {
        if (originalSignal !== undefined) originalSignal.removeEventListener('abort', forwardAbort)
      }
    } finally {
      activeApprovals = Math.max(0, activeApprovals - 1)
    }
  }, { prepend: true })

  ctx.on('user-questions/request', async (req, next) => {
    activeQuestions += 1
    try {
      if (req?.wait?.timed === true) return next()
      if (!Array.isArray(req?.questions) || req.questions.length === 0) return next()
      const session = req.agent?.session
      if (session === undefined || isSubagentSession(session)) return next()
      if (!hasSurface()) return next()

      const originalSignal = req.signal
      const controller = new AbortController()
      const forwardAbort = () => controller.abort()
      if (originalSignal !== undefined) {
        if (originalSignal.aborted) controller.abort()
        else originalSignal.addEventListener('abort', forwardAbort, { once: true })
      }

      const pending = store.create({
        kind: 'question',
        sessionId: session.id,
        callId: req.wait?.callId,
        questions: req.questions,
        coDisplay: true,
        signal: originalSignal,
      })

      try {
        moteAttention.hold(pending.reqId, 'question')
        try {
          req.signal = controller.signal
          return await runCoDisplay({ store, pending, next, controller })
        } finally {
          moteAttention.release(pending.reqId)
        }
      } finally {
        if (originalSignal !== undefined) originalSignal.removeEventListener('abort', forwardAbort)
      }
    } finally {
      activeQuestions = Math.max(0, activeQuestions - 1)
    }
  }, { prepend: true })

  ctx.inject(['webServer'], (webCtx) => {
    try { power.attachOrigin(webCtx.webServer.getOrigin()) } catch { /* port not bound yet */ }

    let port = 0
    let protocol = 'http:'
    try {
      port = Number(webCtx.webServer.port)
      protocol = webCtx.webServer.protocol ?? 'http:'
    } catch { /* use fallbacks below */ }
    if (!Number.isInteger(port) || port <= 0) {
      try { port = Number(new URL(webCtx.webServer.getOrigin()).port) } catch { /* keep 0 */ }
    }
    const localHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`])
    const localOrigins = new Set([...localHosts].map(host => `${protocol}//${host}`))

    const isLocalHost = req => localHosts.has(String(req.headers.host ?? '').toLowerCase())
    const isAllowedOrigin = req => {
      const origin = req.headers.origin
      if (origin === undefined) return true
      return localOrigins.has(String(origin).toLowerCase())
    }

    function denied(res, status, source) {
      audit.record({
        source,
        principal: 'unknown',
        kind: 'access',
        outcome: `denied-${status}`,
      })
      sendJson(res, status, {
        ok: false,
        error: status === 401 ? 'unauthorized' : 'forbidden',
      })
    }

    function guardApp(req, res, { post = false, auditSource = 'app' } = {}) {
      if (!isLoopback(req.socket.remoteAddress) || !isLocalHost(req)) {
        denied(res, 403, auditSource)
        return false
      }
      if (post && !isAllowedOrigin(req)) {
        denied(res, 403, auditSource)
        return false
      }
      if (!appAuth.verify(req)) {
        denied(res, 401, auditSource)
        return false
      }
      return true
    }

    function guardRegister(req, res) {
      if (!isLoopback(req.socket.remoteAddress) || !isLocalHost(req) || !isAllowedOrigin(req)) {
        denied(res, 403, 'app')
        return false
      }
      return true
    }

    function postOnly(req, res) {
      if (req.method !== 'POST') {
        sendJson(res, 405, { ok: false, error: 'method-not-allowed' })
        return false
      }
      return true
    }

    function bearerOf(req) {
      const value = req.headers.authorization
      if (typeof value !== 'string') return undefined
      const match = /^Bearer\s+(\S+)\s*$/i.exec(value)
      return match?.[1]
    }

    function rotateDenied(res, status, error) {
      audit.record({
        source: 'app',
        principal: 'unknown',
        kind: 'app-auth',
        outcome: 'denied',
      })
      sendJson(res, status, { ok: false, error })
    }

    function guardRotate(req, res) {
      if (!isLoopback(req.socket.remoteAddress) || !isLocalHost(req)) {
        rotateDenied(res, 403, 'forbidden')
        return false
      }
      if (req.method !== 'POST') {
        rotateDenied(res, 405, 'method-not-allowed')
        return false
      }
      if (!isAllowedOrigin(req)) {
        rotateDenied(res, 403, 'forbidden')
        return false
      }
      if (!appAuth.verify(req)) {
        rotateDenied(res, 401, 'unauthorized')
        return false
      }
      return true
    }

    // --- App routes (Keychain bearer, loopback + exact DSH Host) ----------

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/app/register`,
      handler: async (req, res) => {
        if (!guardRegister(req, res) || !postOnly(req, res)) return
        let body
        try { body = await readJson(req) } catch (error) {
          sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
          return
        }
        let result
        try {
          result = appAuth.register(typeof body?.token === 'string' ? body.token : '')
        } catch (error) {
          audit.record({ source: 'app', principal: 'app', kind: 'app-auth', outcome: 'failed' })
          sendJson(res, 500, { ok: false, error: 'app-auth-unavailable' })
          return
        }
        const status = result === 'created' || result === 'ok' ? 200
          : result === 'conflict' ? 409 : 400
        audit.record({
          source: 'app',
          principal: 'app',
          kind: 'app-auth',
          outcome: result,
        })
        sendJson(res, status, { ok: status === 200, status: result, state: result })
      },
    }), 'cue9-phone: app register')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/app/rotate`,
      handler: async (req, res) => {
        if (!guardRotate(req, res)) return
        let body
        try { body = await readJson(req) } catch {
          rotateDenied(res, 400, 'invalid')
          return
        }
        const nextToken = typeof body?.token === 'string' ? body.token : ''
        let result
        try {
          result = appAuth.rotate(bearerOf(req), nextToken)
        } catch {
          rotateDenied(res, 500, 'app-auth-unavailable')
          return
        }
        if (result === 'rotated') {
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'app-auth',
            outcome: 'rotated',
          })
          sendJson(res, 200, { ok: true, status: 'rotated' })
          return
        }
        if (result === 'unauthorized') {
          rotateDenied(res, 401, 'unauthorized')
          return
        }
        rotateDenied(res, 400, 'invalid')
      },
    }), 'cue9-phone: app rotate')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup`,
      handler: async (req, res) => {
        if (!guardApp(req, res)) return
        if (req.method !== 'GET') return sendJson(res, 405, { ok: false, error: 'method-not-allowed' })
        try {
          const status = await setupStatus({ config, phone, push, sessions })
          sendJson(res, 200, safeSetupStatus(status))
        } catch (error) {
          sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
        }
      },
    }), 'cue9-phone: setup status')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup/pairing`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: true })) return
        if (!postOnly(req, res)) return
        if (typeof config.publicOrigin !== 'string' || config.publicOrigin.length === 0) {
          return sendJson(res, 409, { ok: false, error: 'phone-link-not-configured' })
        }
        let minted
        try {
          minted = sessions.mintPairing(PAIRING_TTL_MS)
        } catch {
          return sendJson(res, 500, { ok: false, error: 'pairing-unavailable' })
        }
        if (minted === undefined || typeof minted.token !== 'string') {
          return sendJson(res, 500, { ok: false, error: 'pairing-unavailable' })
        }
        const origin = config.publicOrigin.replace(/\/+$/, '')
        audit.record({
          source: 'app',
          principal: 'app',
          kind: 'pairing',
          outcome: 'minted',
        })
        sendJson(res, 200, {
          ok: true,
          token: minted.token,
          url: `${origin}/pair?token=${encodeURIComponent(minted.token)}`,
          expiresAt: minted.expiresAt,
        })
      },
    }), 'cue9-phone: setup pairing')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup/apply`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: true })) return
        if (!postOnly(req, res)) return
        try {
          await applySetup({ config, log: console.log })
          if (phone !== undefined) {
            await phone.stop()
            await phone.start()
          }
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'setup',
            outcome: 'applied',
          })
          sendJson(res, 200, safeSetupStatus(await setupStatus({ config, phone, push, sessions })))
        } catch (error) {
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'setup',
            outcome: 'failed',
          })
          sendJson(res, 400, { ok: false, error: String(error?.message ?? error) })
        }
      },
    }), 'cue9-phone: setup apply')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup/reset`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: true })) return
        if (!postOnly(req, res)) return
        try {
          const result = await resetSetup({ config, phone, push, sessions, log: console.log })
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'reset',
            outcome: 'reset',
          })
          sendJson(res, 200, result)
        } catch (error) {
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'reset',
            outcome: 'failed',
          })
          sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
        }
      },
    }), 'cue9-phone: setup reset')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup/revoke`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: true })) return
        if (!postOnly(req, res)) return
        let body
        try { body = await readJson(req) } catch (error) {
          return sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        }
        const deviceId = typeof body?.deviceId === 'string' && body.deviceId.length > 0 ? body.deviceId : undefined
        let revoked
        let devices
        try {
          if (deviceId === undefined) {
            revoked = sessions.revokeAll()
            try { await push.removeAll?.() } catch { /* push cleanup is best effort */ }
          } else {
            revoked = sessions.revoke(deviceId) === true ? 1 : 0
            try { await push.removeDevice?.(deviceId) } catch { /* push cleanup is best effort */ }
          }
          devices = sessions.listDevices()
        } catch {
          return sendJson(res, 500, { ok: false, error: 'revoke-unavailable' })
        }
        audit.record({
          source: 'app',
          principal: 'app',
          deviceId,
          kind: 'revoke',
          outcome: deviceId === undefined ? 'revoked-all' : 'revoked',
        })
        sendJson(res, 200, { ok: true, revoked, devices })
      },
    }), 'cue9-phone: setup revoke')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/setup/test-push`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: true })) return
        if (!postOnly(req, res)) return
        try {
          const result = await push.test()
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'test-push',
            outcome: result?.ok ? 'sent' : 'failed',
          })
          sendJson(res, result?.ok ? 200 : 400, result ?? { ok: false, error: 'push-not-configured' })
        } catch (error) {
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'test-push',
            outcome: 'failed',
          })
          sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
        }
      },
    }), 'cue9-phone: setup test push')

    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: `${PHONE_PREFIX}/power`,
      handler: async (req, res) => {
        if (!guardApp(req, res, { post: req.method === 'POST' })) return
        if (req.method === 'GET') {
          sendJson(res, 200, { ok: true, ...power.state() })
          return
        }
        if (!postOnly(req, res)) return
        try {
          const body = await readJson(req)
          const state = power.setEnabled(body?.enabled === true)
          audit.record({
            source: 'app',
            principal: 'app',
            kind: 'power',
            outcome: state.enabled ? 'enabled' : 'disabled',
          })
          sendJson(res, 200, { ok: true, ...state })
        } catch (error) {
          sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        }
      },
    }), 'cue9-phone: power')
  })

  ctx.effect(() => {
    if (phone !== undefined) {
      void phone.start().catch(error => {
        console.error('[cue9-phone] failed to start phone surface:', error?.message ?? error)
      })
    }
    return () => {
      power.dispose()
      store.dispose()
      void phone?.stop()
    }
  }, 'cue9-phone: lifecycle')
}
