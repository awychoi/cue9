import test from 'node:test'
import assert from 'node:assert/strict'
import { runCoDisplay } from '../index.js'
import { RequestStore } from '../lib/store.js'

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

function approval(store, options = {}) {
  return store.create({
    kind: 'approval',
    sessionId: 's1',
    callId: 'c1',
    toolName: 'bash',
    args: { command: 'echo hi' },
    coDisplay: true,
    ...options,
  })
}

function question(store) {
  return store.create({
    kind: 'question',
    sessionId: 's1',
    callId: 'q1',
    questions: [{ id: 'q1', question: 'Pick', options: [{ label: 'A' }] }],
    coDisplay: true,
  })
}

test('DSH-first settles the phone surface and returns the DSH value', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = approval(store)
  const controller = new AbortController()
  let calls = 0

  const value = await runCoDisplay({
    store,
    pending,
    controller,
    next: async () => { calls += 1; return 'allowed-once' },
  })

  assert.equal(value, 'allowed-once')
  assert.equal(calls, 1)
  assert.equal(controller.signal.aborted, false)
  assert.equal(store.list().length, 0)
  assert.equal(events.at(-1).source, 'dsh')
  assert.equal(events.at(-1).outcome, 'allowed-once')
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})

test('phone-first aborts the DSH signal and returns the phone answer', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = approval(store)
  const controller = new AbortController()
  const dsh = Promise.withResolvers()
  let calls = 0

  const run = runCoDisplay({
    store,
    pending,
    controller,
    next: () => { calls += 1; return dsh.promise },
  })
  await Promise.resolve()
  assert.equal(store.answer(pending.reqId, { outcome: 'rejected' }, 'phone', claim()).ok, true)
  assert.equal(await run, 'rejected')
  assert.equal(controller.signal.aborted, true)
  assert.equal(calls, 1)
  assert.equal(events.at(-1).source, 'phone')
  assert.equal(store.list().length, 0)

  dsh.resolve('late DSH answer')
  await delay(5)
  assert.equal(calls, 1)
})

test('timeout closes phone but keeps waiting for DSH', async () => {
  const store = new RequestStore({ ttlMs: 20 })
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = approval(store)
  const controller = new AbortController()
  const dsh = Promise.withResolvers()
  let calls = 0
  let finished = false

  const run = runCoDisplay({
    store,
    pending,
    controller,
    next: () => { calls += 1; return dsh.promise },
  }).finally(() => { finished = true })

  await delay(50)
  assert.equal(finished, false)
  assert.equal(controller.signal.aborted, false)
  assert.equal(calls, 1)
  assert.equal(store.list().length, 0)
  assert.equal(events.at(-1).source, 'timeout')
  assert.equal(await surfaceOutcome(pending.promise), 'pending')

  dsh.resolve('allowed-once')
  assert.equal(await run, 'allowed-once')
  assert.equal(finished, true)
  assert.equal(calls, 1)
})

test('question phone-first returns the answered question batch', async () => {
  const store = new RequestStore()
  const pending = question(store)
  const controller = new AbortController()
  const dsh = Promise.withResolvers()
  let calls = 0
  const answers = {
    answers: [
      { id: 'q1', selected: ['A'] },
    ],
  }

  const run = runCoDisplay({
    store,
    pending,
    controller,
    next: () => { calls += 1; return dsh.promise },
  })
  await Promise.resolve()
  assert.equal(store.answer(pending.reqId, answers, 'phone', claim('s1', 'q1')).ok, true)
  assert.deepEqual(await run, answers)
  assert.equal(controller.signal.aborted, true)
  assert.equal(calls, 1)
  dsh.resolve({ answers: [] })
})

test('DSH rejection closes phone and propagates the DSH error', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = approval(store)
  const controller = new AbortController()

  await assert.rejects(runCoDisplay({
    store,
    pending,
    controller,
    next: async () => { throw new Error('cancelled by DSH') },
  }), /cancelled by DSH/)

  assert.equal(store.list().length, 0)
  assert.equal(events.at(-1).source, 'dsh-abort')
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})

test('DSH-first question closes the phone surface and returns DSH answers', async () => {
  const store = new RequestStore()
  const events = []
  store.on('resolved', event => events.push(event))
  const pending = question(store)
  const controller = new AbortController()
  const answers = { answers: [{ id: 'q1', selected: ['A'] }] }

  const value = await runCoDisplay({
    store,
    pending,
    controller,
    next: async () => answers,
  })

  assert.deepEqual(value, answers)
  assert.equal(controller.signal.aborted, false)
  assert.equal(store.list().length, 0)
  assert.equal(events.at(-1).source, 'dsh')
  assert.deepEqual(events.at(-1).answers, answers.answers)
  assert.equal(await surfaceOutcome(pending.promise), 'pending')
})
