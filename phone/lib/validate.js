/** Shared limits and answer validation for the cue9 phone bridge. */

export const MAX_APPROVAL_ARGS_BYTES = 64 * 1024
export const MAX_CUSTOM_CHARS = 4000
export const MAX_BODY_BYTES = 256 * 1024

const REQUEST_TITLES = Object.freeze({
  approval: 'Approval needed',
  question: 'Question from cue9',
})

/** Neutral card/push title; never contains the tool reason or question text. */
export function requestTitle(kind) {
  return REQUEST_TITLES[kind] ?? REQUEST_TITLES.approval
}

/**
 * Copy approval arguments so a later mutation by the tool/agent cannot change
 * what the panel or phone displays. Uses structuredClone when available and
 * falls back to JSON for plain values. Returns undefined when uncopyable.
 */
export function cloneApprovalArguments(value) {
  if (value === undefined) return undefined
  try {
    if (typeof structuredClone === 'function') return structuredClone(value)
  } catch { /* fall through to JSON */ }
  try {
    return JSON.parse(JSON.stringify(value))
  } catch {
    return undefined
  }
}

/** Whether an address is this machine. Accepts IPv4, IPv6 and mapped forms. */
export function isLoopback(address) {
  const value = String(address ?? '')
  return value === '::1'
    || value === '::ffff:127.0.0.1'
    || value.startsWith('127.')
}

/** Whether a Session belongs to a delegated child. */
export function isSubagentSession(session) {
  return session?.header?.origin === 'subagent'
}

/** Lossless JSON size of a value, or Infinity when it cannot be encoded. */
export function jsonSize(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value) ?? '', 'utf8')
  } catch {
    return Number.POSITIVE_INFINITY
  }
}

/** The only answers an approval card may send. */
export function validateApprovalAnswer(value) {
  const outcome = value?.outcome
  if (outcome !== 'allowed-once' && outcome !== 'rejected') return undefined
  return { outcome }
}

/**
 * Validate one complete question batch against the request's own questions.
 * Empty selected + no custom is the user's explicit skip.
 * @returns normalized answers, or undefined when the batch is malformed.
 */
export function validateQuestionAnswer(value, questions) {
  if (!Array.isArray(value?.answers)) return undefined
  if (!Array.isArray(questions) || questions.length === 0) return undefined
  if (value.answers.length !== questions.length) return undefined

  const byId = new Map(questions.map(question => [question.id, question]))
  const seen = new Set()
  const answers = []

  for (const item of value.answers) {
    if (typeof item?.id !== 'string' || seen.has(item.id)) return undefined
    const question = byId.get(item.id)
    if (question === undefined) return undefined
    seen.add(item.id)

    const rawSelected = item.selected ?? []
    if (!Array.isArray(rawSelected) || !rawSelected.every(label => typeof label === 'string')) return undefined
    const labels = new Set((question.options ?? []).map(option => option.label))
    if (!rawSelected.every(label => labels.has(label))) return undefined

    const selected = question.multiSelect === true
      ? [...new Set(rawSelected)]
      : rawSelected.slice(0, 1)
    if (question.multiSelect !== true && rawSelected.length > 1) return undefined

    const custom = typeof item.custom === 'string' ? item.custom.trim() : ''
    if (custom.length > MAX_CUSTOM_CHARS) return undefined
    // Single-select custom replaces the choice; it never accompanies one.
    if (question.multiSelect !== true && custom.length > 0 && selected.length > 0) return undefined

    answers.push({
      id: item.id,
      selected,
      ...(custom.length > 0 ? { custom } : {}),
    })
  }

  return { answers }
}

/** Pick the English localized presentation text, falling back to the raw reason. */
export function displayReasonOf(request) {
  const localized = request?.displayReason
  if (localized !== undefined && typeof localized === 'object') {
    if (typeof localized.en === 'string' && localized.en.length > 0) return localized.en
    for (const value of Object.values(localized)) {
      if (typeof value === 'string' && value.length > 0) return value
    }
  }
  return typeof request?.reason === 'string' ? request.reason : undefined
}

/** The command-like text of an approval's arguments for the code block. */
export function commandOf(args) {
  if (args === null || typeof args !== 'object') return undefined
  if (typeof args.command === 'string' && args.command.length > 0) return args.command
  if (typeof args.text === 'string' && args.text.length > 0) return args.text
  return undefined
}
