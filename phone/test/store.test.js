import test from 'node:test'
import assert from 'node:assert/strict'
import { RequestStore } from '../lib/store.js'
import {
  cloneApprovalArguments,
  commandOf,
  isLoopback,
  jsonSize,
  requestTitle,
  validateApprovalAnswer,
  validateQuestionAnswer,
} from '../lib/validate.js'

function claim(sessionId = 's1', callId = 'c1') {
  return { sessionId, callId }
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function surfaceOutcome(promise, ms = 25) {
  return Promise.race([
    promise.then(() => 'resolved', () => 'rejected'),
    delay(ms).then(() => 'pending'),
  ])
}

function approval(store, overrides = {}) {
  return store.create({
    kind: 'approval',
    sessionId: 's1',
    callId: 'c1',
    toolName: 'bash',
    args: { command: 'echo hi > /tmp/x' },
    cwd: '/tmp',
    next: async () => 'rejected',
    ...overrides,
  })
}

const questions = [
  { id: 'q1', question: 'Pick one', options: [{ label: 'A' }, { label: 'B' }] },
  { id: 'q2', question: 'Pick many', multiSelect: true, options: [{ label: 'X' }, { label: 'Y' }] },
]

test('approval allow resolves the waiting answerer and leaves the store', async () => {
  const store = new RequestStore()
  const pending = approval(store)
  const result = store.answer(pending.reqId, { outcome: 'allowed-once' }, 'phone', claim())
  assert.equal(result.ok, true)
  assert.equal(await pending.promise, 'allowed-once')
  assert.equal(store.list().length, 0)
})

test('approval requires the exact session and call claim', async () => {
  const store = new RequestStore()
  const pending = approval(store)
  assert.deepEqual(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim('s2', 'c1')), {
    ok: false,
    error: 'claim-mismatch',
  })
  assert.deepEqual(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim('s1', 'c2')), {
    ok: false,
    error: 'claim-mismatch',
  })
  assert.deepEqual(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel'), {
    ok: false,
    error: 'claim-mismatch',
  })
  assert.equal(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim()).ok, true)
})

test('undefined and null call ids are equivalent for a claim', async () => {
  const store = new RequestStore()
  const pending = approval(store, { callId: undefined })
  assert.equal(store.answer(pending.reqId, { outcome: 'allowed-once' }, 'phone', { sessionId: 's1', callId: null }).ok, true)
})

test('approval rejects malformed or late answers', async () => {
  const store = new RequestStore()
  const pending = approval(store)
  assert.equal(store.answer(pending.reqId, { outcome: 'yes' }, 'phone', claim()).error, 'invalid-answer')
  assert.equal(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim()).ok, true)
  assert.equal(store.answer(pending.reqId, { outcome: 'rejected' }, 'phone', claim()).error, 'not-found')
  assert.equal(await pending.promise, 'rejected')
})

test('approval handoff delegates to the DSH answerer', async () => {
  const store = new RequestStore()
  let called = 0
  const pending = store.create({
    kind: 'approval',
    sessionId: 's1',
    callId: 'c1',
    toolName: 'bash',
    args: { command: 'ls' },
    next: async () => { called += 1; return 'allowed-once' },
  })
  const result = await store.handoff(pending.reqId, 'panel', claim())
  assert.equal(result.ok, true)
  assert.equal(called, 1)
  assert.equal(await pending.promise, 'allowed-once')
})

test('handoff requires the claim while internal handoff does not', async () => {
  const store = new RequestStore()
  const pending = approval(store)
  assert.deepEqual(await store.handoff(pending.reqId, 'panel', claim('s2')), {
    ok: false,
    error: 'claim-mismatch',
  })
  const internal = await store.handoffInternal(pending.reqId, 'orphan')
  assert.equal(internal.ok, true)
  assert.equal(await pending.promise, 'rejected')
})

test('co-display DSH settlement closes phone without resolving its promise', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  let called = 0
  const pending = approval(store, {
    coDisplay: true,
    next: async () => { called += 1; return 'rejected' },
  })

  assert.equal(store.settleFromDsh(pending.reqId, 'allowed-once'), true)
  assert.equal(called, 0)
  assert.equal(store.list().length, 0)
  assert.equal(events.length, 1)
  assert.equal(events[0].source, 'dsh')
  assert.equal(events[0].outcome, 'allowed-once')
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
  assert.deepEqual(
    store.answer(pending.reqId, { outcome: 'rejected' }, 'phone', claim()),
    { ok: false, error: 'not-found' },
  )
  assert.equal(store.settleFromDsh(pending.reqId, 'late'), false)
})

test('co-display timeout closes phone and never calls next', async () => {
  const store = new RequestStore({ ttlMs: 15 })
  const events = []
  store.on('resolved', event => events.push(event))
  let called = 0
  const pending = approval(store, {
    coDisplay: true,
    next: async () => { called += 1; return 'rejected' },
  })

  await delay(45)
  assert.equal(called, 0)
  assert.equal(store.list().length, 0)
  assert.equal(events.length, 1)
  assert.equal(events[0].source, 'timeout')
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})

test('co-display disables handoff so next cannot run twice', async () => {
  const store = new RequestStore()
  let called = 0
  const pending = approval(store, {
    coDisplay: true,
    next: async () => { called += 1; return 'rejected' },
  })

  assert.deepEqual(await store.handoff(pending.reqId, 'panel', claim()), {
    ok: false,
    error: 'handoff-disabled',
  })
  assert.deepEqual(await store.handoffInternal(pending.reqId, 'timeout'), {
    ok: false,
    error: 'handoff-disabled',
  })
  assert.equal(called, 0)
  assert.equal(pending.settled, false)
  assert.equal(store.abortFromDsh(pending.reqId, new Error('cancelled')), true)
})

test('co-display abortFromDsh closes phone without a result', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = approval(store, { coDisplay: true })

  assert.equal(store.abortFromDsh(pending.reqId, new Error('cancelled')), true)
  assert.equal(store.list().length, 0)
  assert.equal(events.length, 1)
  assert.equal(events[0].source, 'dsh-abort')
  assert.equal(events[0].outcome, undefined)
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})

test('co-display question DSH settlement carries answers only to the surface event', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = store.create({
    kind: 'question',
    sessionId: 's1',
    callId: 'c2',
    questions,
    coDisplay: true,
  })
  const answers = { answers: [{ id: 'q1', selected: ['A'] }, { id: 'q2', selected: [] }] }
  assert.equal(store.settleFromDsh(pending.reqId, answers), true)
  assert.equal(events[0].source, 'dsh')
  assert.deepEqual(events[0].answers, answers.answers)
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})

test('abort settles an approval as cancelled', async () => {
  const store = new RequestStore()
  const controller = new AbortController()
  const pending = approval(store, { signal: controller.signal })
  controller.abort()
  assert.equal(await pending.promise, 'cancelled')
  assert.equal(store.list().length, 0)
})

test('question batch accepts one answer per question and custom text', async () => {
  const store = new RequestStore()
  const pending = store.create({
    kind: 'question',
    sessionId: 's1',
    callId: 'c2',
    questions,
    next: async () => ({ answers: [] }),
  })
  const result = store.answer(pending.reqId, {
    answers: [
      { id: 'q1', selected: ['A'] },
      { id: 'q2', selected: ['X'], custom: 'maybe Y too' },
    ],
  }, 'phone', claim('s1', 'c2'))
  assert.equal(result.ok, true)
  assert.deepEqual(await pending.promise, {
    answers: [
      { id: 'q1', selected: ['A'] },
      { id: 'q2', selected: ['X'], custom: 'maybe Y too' },
    ],
  })
})

test('question batch rejects missing, extra, or invalid choices', () => {
  assert.equal(validateQuestionAnswer({ answers: [{ id: 'q1', selected: ['A'] }] }, questions), undefined)
  assert.equal(validateQuestionAnswer({
    answers: [
      { id: 'q1', selected: ['A'] },
      { id: 'q2', selected: ['X'] },
      { id: 'q3', selected: [] },
    ],
  }, questions), undefined)
  assert.equal(validateQuestionAnswer({
    answers: [
      { id: 'q1', selected: ['NOPE'] },
      { id: 'q2', selected: [] },
    ],
  }, questions), undefined)
  assert.equal(validateQuestionAnswer({
    answers: [
      { id: 'q1', selected: ['A', 'B'] },
      { id: 'q2', selected: [] },
    ],
  }, questions), undefined)
  assert.equal(validateQuestionAnswer({
    answers: [
      { id: 'q1', selected: ['A'], custom: 'both' },
      { id: 'q2', selected: [] },
    ],
  }, questions), undefined)
})

test('single-select custom replaces the choice; empty means skip', () => {
  assert.deepEqual(validateQuestionAnswer({
    answers: [
      { id: 'q1', selected: [], custom: 'C' },
      { id: 'q2', selected: [] },
    ],
  }, questions), {
    answers: [
      { id: 'q1', selected: [], custom: 'C' },
      { id: 'q2', selected: [] },
    ],
  })
})

test('ack requires the claim and reports missing/settled requests', async () => {
  const store = new RequestStore()
  const pending = approval(store)
  assert.deepEqual(store.ack(pending.reqId, 'panel', claim('s2')), {
    ok: false,
    error: 'claim-mismatch',
  })
  assert.deepEqual(store.ack('missing', 'panel', claim()), {
    ok: false,
    error: 'not-found',
  })
  assert.deepEqual(store.ack(pending.reqId, 'panel', claim()), { ok: true })
  assert.equal(await store.waitForAck(pending.reqId, 50), true)
  assert.equal(store.inspect(pending.reqId)?.sessionId, 's1')
  assert.equal(store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim()).ok, true)
  assert.equal(store.inspect(pending.reqId), undefined)
  assert.deepEqual(store.ack(pending.reqId, 'panel', claim()), { ok: false, error: 'not-found' })
})

test('validate and format helpers behave', () => {
  assert.deepEqual(validateApprovalAnswer({ outcome: 'rejected' }), { outcome: 'rejected' })
  assert.equal(validateApprovalAnswer({ outcome: 'allowed-always' }), undefined)
  assert.equal(isLoopback('127.0.0.1'), true)
  assert.equal(isLoopback('::ffff:127.0.0.1'), true)
  assert.equal(isLoopback('100.64.0.1'), false)
  assert.equal(commandOf({ command: 'ls' }), 'ls')
  assert.equal(commandOf({ command: 'ls', text: 'ignored' }), 'ls')
  assert.ok(jsonSize({ a: 1 }) > 0)
  assert.equal(requestTitle('approval'), 'Approval needed')
  assert.equal(requestTitle('question'), 'Question from cue9')
})

test('store view carries neutral titles, not the reason', () => {
  const store = new RequestStore()
  const pendingApproval = approval(store, {
    displayReason: 'Remove the temporary file',
    reason: 'Remove the temporary file',
  })
  const approvalView = store.inspect(pendingApproval.reqId)
  assert.equal(approvalView.title, 'Approval needed')
  assert.equal(approvalView.displayReason, 'Remove the temporary file')
  assert.equal(approvalView.command, 'echo hi > /tmp/x')

  const pendingQuestion = store.create({
    kind: 'question',
    sessionId: 's1',
    callId: 'q-call',
    questions,
    next: async () => ({ answers: [] }),
  })
  const questionView = store.inspect(pendingQuestion.reqId)
  assert.equal(questionView.title, 'Question from cue9')
  assert.equal(questionView.questions[0].question, 'Pick one')

  store.answer(pendingApproval.reqId, { outcome: 'rejected' }, 'panel', claim())
  store.answer(pendingQuestion.reqId, {
    answers: [
      { id: 'q1', selected: ['A'] },
      { id: 'q2', selected: [] },
    ],
  }, 'panel', claim('s1', 'q-call'))
})

test('cached approval arguments are independent copies', () => {
  const store = new RequestStore()
  const original = { command: 'echo original', nested: { value: 1 } }
  const cached = cloneApprovalArguments(original)
  const pending = approval(store, { args: cached })
  const view = store.inspect(pending.reqId)

  original.command = 'echo changed'
  original.nested.value = 2

  assert.equal(view.args.command, 'echo original')
  assert.equal(view.args.nested.value, 1)
  assert.notEqual(view.args, original)
  store.answer(pending.reqId, { outcome: 'rejected' }, 'panel', claim())
})
