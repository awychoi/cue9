import test from 'node:test'
import assert from 'node:assert/strict'
import { buildPushPayload } from '../lib/push.js'
import { cloneApprovalArguments, requestTitle } from '../lib/validate.js'

const secrets = [
  'SECRET_COMMAND',
  'SECRET_ARG',
  'SECRET_REASON',
  'SECRET_DISPLAY',
  'SECRET_QUESTION',
  'SECRET_CWD',
  'SECRET_SESSION',
]

function request(overrides = {}) {
  return {
    reqId: 'r_abc123',
    kind: 'approval',
    toolName: 'bash',
    command: 'SECRET_COMMAND',
    args: { command: 'SECRET_ARG', path: '/SECRET_CWD' },
    reason: 'SECRET_REASON',
    displayReason: 'SECRET_DISPLAY',
    cwd: 'SECRET_CWD',
    sessionId: 'SECRET_SESSION',
    questions: [{ id: 'q1', question: 'SECRET_QUESTION' }],
    ...overrides,
  }
}

function assertNeutral(payload, expectedTitle, expectedBody) {
  assert.equal(payload.title, expectedTitle)
  assert.equal(payload.body, expectedBody)
  assert.match(payload.url, /^\/#\/r\/[^/]+$/)
  assert.equal(payload.url, '/#/r/r_abc123')
  assert.equal(payload.tag, 'r_abc123')
  assert.deepEqual(Object.keys(payload).sort(), ['body', 'tag', 'title', 'url'])
  const text = JSON.stringify(payload)
  for (const secret of secrets) assert.equal(text.includes(secret), false, `leaked ${secret}`)
}

test('approval push payload is neutral and contains no request content', () => {
  const payload = JSON.parse(buildPushPayload(request()))
  assertNeutral(payload, 'Approval needed', 'Open cue9 to review.')
})

test('question push payload is neutral and contains no question text', () => {
  const payload = JSON.parse(buildPushPayload(request({
    kind: 'question',
    toolName: undefined,
    command: undefined,
    args: undefined,
  })))
  assertNeutral(payload, 'Question from cue9', 'Open cue9 to answer.')
})

test('push payload ignores a forged title and reason', () => {
  const payload = JSON.parse(buildPushPayload(request({
    kind: 'approval',
    title: 'SECRET_DISPLAY',
    body: 'SECRET_REASON',
  })))
  assertNeutral(payload, 'Approval needed', 'Open cue9 to review.')
})

test('neutral title helper is fixed per kind', () => {
  assert.equal(requestTitle('approval'), 'Approval needed')
  assert.equal(requestTitle('question'), 'Question from cue9')
})

test('cloned approval args do not alias the original object', () => {
  const original = { command: 'SECRET_COMMAND', nested: { values: ['SECRET_ARG'] } }
  const copy = cloneApprovalArguments(original)
  original.command = 'changed'
  original.nested.values.push('changed')
  assert.equal(copy.command, 'SECRET_COMMAND')
  assert.deepEqual(copy.nested.values, ['SECRET_ARG'])
  assert.notEqual(copy, original)
  assert.notEqual(copy.nested, original.nested)
})
