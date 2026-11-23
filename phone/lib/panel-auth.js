/**
 * Panel authentication: reuse DSH's browser/API Peer admission.
 *
 * The laptop panel is served from the DSH origin, so its fetch/EventSource
 * carries DSH's signed browser cookie. `connection.admit` applies DSH's
 * Host/Origin fence and cookie verification. We require the owner principal
 * and fail closed when Connection is unavailable.
 */

/**
 * @param {{ ctx: { get?: (name: string) => unknown } }} options
 * @returns {(req: import('node:http').IncomingMessage) => ({ ok: true, peer: object } | { ok: false, status: 401 | 403 })}
 */
export function createPanelGuard({ ctx }) {
  return function guard(req) {
    let connection
    try {
      connection = typeof ctx?.get === 'function' ? ctx.get('connection') : undefined
    } catch {
      return { ok: false, status: 401 }
    }
    if (connection === undefined || connection === null || typeof connection.admit !== 'function') {
      return { ok: false, status: 401 }
    }

    let admission
    try {
      admission = connection.admit(req)
    } catch {
      return { ok: false, status: 401 }
    }
    if (admission === undefined || admission === null) return { ok: false, status: 401 }
    if ('rejection' in admission) {
      return { ok: false, status: admission.rejection === 403 ? 403 : 401 }
    }

    const peer = admission.peer
    if (peer === undefined || peer === null) return { ok: false, status: 401 }
    if (peer.principal?.kind !== 'owner') return { ok: false, status: 403 }
    return { ok: true, peer }
  }
}
