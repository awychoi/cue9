/** In-memory pending approvals/questions shared by the phone and DSH. */
import { EventEmitter } from 'node:events'
import { randomUUID } from 'node:crypto'
import {
  commandOf,
  displayReasonOf,
  requestTitle,
  validateApprovalAnswer,
  validateQuestionAnswer,
} from './validate.js'

const DEFAULT_TTL_MS = 10 * 60 * 1000

/** A client answer must name the session and call it actually saw. */
function claimMatches(pending, claim) {
  if (claim === null || typeof claim !== 'object') return false
  if (claim.sessionId !== pending.sessionId) return false
  const storedCallId = pending.callId ?? null
  const claimedCallId = claim.callId ?? null
  return storedCallId === claimedCallId
}

/** One request store per Host plugin. Resolves the waiting DSH answerer. */
export class RequestStore extends EventEmitter {
  /**
   * @param {{ ttlMs?: number, now?: () => number }} [options]
   */
  constructor(options = {}) {
    super()
    this.ttlMs = Number.isFinite(options.ttlMs) && options.ttlMs > 0 ? options.ttlMs : DEFAULT_TTL_MS
    this.now = typeof options.now === 'function' ? options.now : Date.now
    this.items = new Map()
    this.disposed = false
  }

  /**
   * Hold one request until the phone or DSH itself answers it.
   * @param {object} request - normalized request from the Host listener.
   * @returns {object} the pending record.
   */
  create(request) {
    const reqId = `r_${randomUUID().replaceAll('-', '').slice(0, 16)}`
    const completion = Promise.withResolvers()
    const ackWait = Promise.withResolvers()
    const pending = {
      reqId,
      kind: request.kind,
      sessionId: request.sessionId,
      callId: request.callId,
      toolName: request.toolName,
      args: request.args,
      command: request.command ?? commandOf(request.args),
      cwd: request.cwd,
      reason: request.reason,
      displayReason: request.displayReason ?? displayReasonOf(request),
      questions: request.questions,
      createdAt: this.now(),
      expiresAt: this.now() + this.ttlMs,
      status: 'pending',
      ack: new Set(),
      ackWait,
      promise: completion.promise,
      resolve: completion.resolve,
      reject: completion.reject,
      next: request.next,
      signal: request.signal,
      coDisplay: request.coDisplay === true,
      onAbort: undefined,
      timer: undefined,
      handingOff: undefined,
      settled: false,
    }

    const abort = () => {
      if (pending.coDisplay) {
        this.#closeSurface(pending, 'abort')
        return
      }
      if (pending.kind === 'question') {
        this.#settle(pending, {
          source: 'abort',
          error: new Error('ask_user_question was aborted before the user answered'),
        })
      } else {
        this.#settle(pending, { source: 'abort', value: 'cancelled' })
      }
    }
    if (request.signal !== undefined) {
      pending.onAbort = abort
      request.signal.addEventListener('abort', abort, { once: true })
      if (request.signal.aborted) {
        abort()
        return pending
      }
    }

    pending.timer = setTimeout(() => {
      if (pending.coDisplay) {
        this.#closeSurface(pending, 'timeout')
        return
      }
      void this.handoffInternal(reqId, 'timeout')
    }, this.ttlMs)
    pending.timer.unref?.()

    this.items.set(reqId, pending)
    this.emit('request', this.view(pending))
    return pending
  }

  /** Current pending requests as safe wire values. */
  list() {
    return [...this.items.values()].map(pending => this.view(pending))
  }

  /** Number of approvals/questions still waiting for a human. */
  pendingCount() {
    return this.items.size
  }

  /** View of one pending request, or undefined when missing/settled. */
  inspect(reqId) {
    const pending = this.items.get(reqId)
    return pending === undefined ? undefined : this.view(pending)
  }

  /** Safe wire value for one pending request. */
  view(pending) {
    return {
      reqId: pending.reqId,
      kind: pending.kind,
      title: requestTitle(pending.kind),
      sessionId: pending.sessionId,
      callId: pending.callId,
      toolName: pending.toolName,
      args: pending.args,
      command: pending.command,
      cwd: pending.cwd,
      reason: pending.reason,
      displayReason: pending.displayReason,
      questions: pending.questions,
      createdAt: pending.createdAt,
      expiresAt: pending.expiresAt,
    }
  }

  /** Whether a request is still held. */
  isPending(reqId) {
    return this.items.has(reqId)
  }

  /** Whether one surface acknowledged this request. */
  ackedBy(reqId, source) {
    return this.items.get(reqId)?.ack.has(source) ?? false
  }

  /** Record that one surface saw the request, bound to the exact claim. */
  ack(reqId, source, claim) {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return { ok: false, error: 'not-found' }
    if (!claimMatches(pending, claim)) return { ok: false, error: 'claim-mismatch' }
    pending.ack.add(String(source))
    pending.ackWait.resolve(true)
    return { ok: true }
  }

  /** Wait for the first surface acknowledgement. */
  async waitForAck(reqId, timeoutMs) {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return false
    if (pending.ack.size > 0) return true
    let timer
    try {
      return await Promise.race([
        pending.ackWait.promise,
        new Promise(resolve => { timer = setTimeout(() => resolve(false), timeoutMs) }),
      ])
    } finally {
      clearTimeout(timer)
    }
  }

  /** Accept an answer from the phone, bound to the claim. */
  answer(reqId, value, source, claim) {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) {
      return { ok: false, error: 'not-found' }
    }
    if (!claimMatches(pending, claim)) return { ok: false, error: 'claim-mismatch' }

    if (pending.kind === 'approval') {
      const answer = validateApprovalAnswer(value)
      if (answer === undefined) return { ok: false, error: 'invalid-answer' }
      this.#settle(pending, { source, value: answer.outcome })
      return { ok: true }
    }

    const answer = validateQuestionAnswer(value, pending.questions)
    if (answer === undefined) return { ok: false, error: 'invalid-answer' }
    this.#settle(pending, { source, value: answer })
    return { ok: true }
  }

  /**
   * DSH answered first: close the phone surface, but leave the phone
   * answer promise unresolved. The Host listener returns the DSH result.
   */
  settleFromDsh(reqId, value, source = 'dsh') {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return false
    return this.#closeSurface(pending, source, value)
  }

  /** DSH rejected/cancelled: close the phone surface without a result. */
  abortFromDsh(reqId, error) {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return false
    return this.#closeSurface(pending, 'dsh-abort')
  }

  /**
   * Hand the request to DSH's own answerer (the shipped approval/question card).
   * Kept for compatibility; co-display never calls this.
   */
  async handoff(reqId, source = 'dsh', claim) {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return { ok: false, error: 'not-found' }
    if (!claimMatches(pending, claim)) return { ok: false, error: 'claim-mismatch' }
    if (pending.coDisplay) return { ok: false, error: 'handoff-disabled' }
    return this.#beginHandoff(pending, source)
  }

  /** Host-owned handoff for timeout, orphan, and no-surface paths. */
  async handoffInternal(reqId, source = 'dsh') {
    const pending = this.items.get(reqId)
    if (pending === undefined || pending.settled) return { ok: false, error: 'not-found' }
    if (pending.coDisplay) return { ok: false, error: 'handoff-disabled' }
    return this.#beginHandoff(pending, source)
  }

  #beginHandoff(pending, source) {
    if (pending.coDisplay) return { ok: false, error: 'handoff-disabled' }
    if (pending.handingOff !== undefined) return pending.handingOff

    pending.handingOff = (async () => {
      this.emit('handoff', { reqId: pending.reqId, kind: pending.kind, source })
      try {
        if (typeof pending.next !== 'function') throw new Error('no DSH answerer available')
        const result = await pending.next()
        this.#settle(pending, { source, value: result })
        return { ok: true }
      } catch (error) {
        this.#settle(pending, { source, error })
        return { ok: false, error: String(error?.message ?? error) }
      }
    })()
    return pending.handingOff
  }

  /** Stop holding everything; used only when the plugin unloads. */
  dispose() {
    this.disposed = true
    for (const pending of [...this.items.values()]) {
      if (pending.kind === 'question') {
        this.#settle(pending, {
          source: 'dispose',
          error: new Error('ask_user_question was cancelled before the user answered'),
        })
      } else {
        this.#settle(pending, { source: 'dispose', value: 'cancelled' })
      }
    }
  }

  /**
   * Remove the phone surface and announce it, without resolving the
   * Host tool result. Used by DSH-first settlement, cancellation, and timeout.
   */
  #closeSurface(pending, source, value) {
    if (pending.settled) return false
    pending.settled = true
    pending.status = 'settled'
    this.items.delete(pending.reqId)
    if (pending.timer !== undefined) clearTimeout(pending.timer)
    if (pending.signal !== undefined && pending.onAbort !== undefined) {
      pending.signal.removeEventListener('abort', pending.onAbort)
    }
    pending.ackWait.resolve(true)

    this.emit('resolved', {
      reqId: pending.reqId,
      kind: pending.kind,
      source,
      ...(pending.kind === 'approval' && value !== undefined ? { outcome: value } : {}),
      ...(pending.kind === 'question' && value?.answers !== undefined ? { answers: value.answers } : {}),
    })
    return true
  }

  #settle(pending, { source, value, error }) {
    if (pending.settled) return
    pending.settled = true
    pending.status = 'settled'
    this.items.delete(pending.reqId)
    if (pending.timer !== undefined) clearTimeout(pending.timer)
    if (pending.signal !== undefined && pending.onAbort !== undefined) {
      pending.signal.removeEventListener('abort', pending.onAbort)
    }
    pending.ackWait.resolve(true)

    if (error !== undefined) pending.reject(error)
    else pending.resolve(value)

    this.emit('resolved', {
      reqId: pending.reqId,
      kind: pending.kind,
      source,
      ...(pending.kind === 'approval' ? { outcome: value } : {}),
      ...(pending.kind === 'question' && value?.answers !== undefined ? { answers: value.answers } : {}),
    })
  }
}
