/**
 * Local security audit: append-only JSONL with a small fixed field set.
 * Never accepts or persists tool arguments, command text, or question text.
 */
import { appendFileSync, chmodSync, mkdirSync, renameSync, statSync, unlinkSync } from 'node:fs'
import { dirname } from 'node:path'

const ROTATE_BYTES = 1024 * 1024
const FIELDS = ['source', 'principal', 'deviceId', 'reqId', 'sessionId', 'kind', 'outcome']

function text(value) {
  if (value === undefined || value === null) return undefined
  return typeof value === 'string' ? value : String(value)
}

/**
 * @param {{ path: string }} options - absolute path to `audit.jsonl`.
 */
export function createAudit({ path }) {
  function rotateIfNeeded() {
    try {
      const size = statSync(path).size
      if (size < ROTATE_BYTES) return
      try {
        renameSync(path, `${path}.1`)
      } catch {
        try {
          unlinkSync(`${path}.1`)
          renameSync(path, `${path}.1`)
        } catch { /* keep appending to the current file */ }
      }
    } catch {
      // Missing file: nothing to rotate.
    }
  }

  function record(entry) {
    try {
      const row = { at: new Date().toISOString() }
      for (const field of FIELDS) {
        const value = text(entry?.[field])
        if (value !== undefined) row[field] = value
      }
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
      rotateIfNeeded()
      appendFileSync(path, `${JSON.stringify(row)}\n`, { mode: 0o600 })
      chmodSync(path, 0o600)
    } catch {
      // Auditing must not turn a denied request into an unhandled error.
    }
  }

  return { record }
}
