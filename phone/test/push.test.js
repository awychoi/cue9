import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createPush } from '../lib/push.js'

function subscription(id) {
  return {
    endpoint: `https://push.example/${id}`,
    keys: { p256dh: `p256dh-${id}`, auth: `auth-${id}` },
  }
}

function makeWebpush(handler) {
  const calls = []
  return {
    calls,
    generateVAPIDKeys: () => ({ publicKey: 'test-public-key', privateKey: 'test-private-key' }),
    setVapidDetails: () => {},
    async sendNotification(subscription, payload, options) {
      calls.push({ subscription, payload, options })
      return handler(subscription, payload, options)
    },
  }
}

function makeLog() {
  const lines = []
  const log = line => { lines.push(String(line)) }
  log.lines = lines
  return log
}

async function withPush(handler, run) {
  const dir = mkdtempSync(join(tmpdir(), 'cue9-push-test-'))
  const log = makeLog()
  const webpush = makeWebpush(handler)
  const push = await createPush({ dir, webpush, log })
  try {
    await run({ push, webpush, log })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function rejection(statusCode) {
  return error => {
    const failure = new Error('push rejected')
    if (statusCode !== undefined) failure.statusCode = statusCode
    throw failure
  }
}

test('test reports no-subscriptions with zero counts when empty', async () => {
  await withPush(async () => ({}), async ({ push }) => {
    assert.deepEqual(await push.test(), {
      ok: false,
      error: 'no-subscriptions',
      sent: 0,
      failed: 0,
    })
  })
})

test('test reports accepted count when Apple accepts', async () => {
  await withPush(async () => ({}), async ({ push, webpush, log }) => {
    push.subscribe('dev_one', subscription('one'))
    const result = await push.test()
    assert.deepEqual(result, { ok: true, sent: 1, failed: 0 })
    assert.equal(webpush.calls.length, 1)
    assert.equal(webpush.calls[0].options.TTL, 120)
    assert.equal(JSON.parse(webpush.calls[0].payload).title, 'cue9 is connected')
    assert.ok(!webpush.calls[0].payload.includes('command'))
    assert.ok(!log.lines.join('\n').includes('push.example'))
    assert.ok(!log.lines.join('\n').includes('p256dh'))
  })
})

test('test reports accepted and failed counts and keeps a non-404/410 subscription', async () => {
  await withPush(async sub => {
    if (sub.endpoint.endsWith('/two')) rejection(500)()
    return {}
  }, async ({ push, log }) => {
    push.subscribe('dev_one', subscription('one'))
    push.subscribe('dev_two', subscription('two'))
    const result = await push.test()
    assert.deepEqual(result, { ok: true, sent: 1, failed: 1 })
    assert.equal(push.hasSubscriptions(), true, '500 subscription is kept')
    assert.ok(log.lines.some(line => line.includes('500')), 'status is reported')
    assert.ok(!log.lines.join('\n').includes('push.example'))
    assert.ok(!log.lines.join('\n').includes('p256dh'))
  })
})

test('test reports push-rejected when every subscription fails', async () => {
  await withPush(async () => rejection(500)(), async ({ push }) => {
    push.subscribe('dev_one', subscription('one'))
    assert.deepEqual(await push.test(), {
      ok: false,
      error: 'push-rejected',
      sent: 0,
      failed: 1,
    })
    assert.equal(push.hasSubscriptions(), true)
  })
})

test('test removes 410 subscriptions and then reports no-subscriptions', async () => {
  await withPush(async () => rejection(410)(), async ({ push, log }) => {
    push.subscribe('dev_one', subscription('one'))
    const first = await push.test()
    assert.deepEqual(first, {
      ok: false,
      error: 'push-rejected',
      sent: 0,
      failed: 1,
    })
    assert.equal(push.hasSubscriptions(), false)
    assert.ok(log.lines.some(line => line.includes('dropped 1')))
    assert.ok(!log.lines.join('\n').includes('push.example'))
    assert.deepEqual(await push.test(), {
      ok: false,
      error: 'no-subscriptions',
      sent: 0,
      failed: 0,
    })
  })
})

test('network errors are reported without leaking the endpoint', async () => {
  await withPush(async () => rejection()(), async ({ push, log }) => {
    push.subscribe('dev_one', subscription('one'))
    assert.deepEqual(await push.test(), {
      ok: false,
      error: 'push-rejected',
      sent: 0,
      failed: 1,
    })
    assert.equal(push.hasSubscriptions(), true)
    assert.ok(log.lines.some(line => line.includes('unknown')))
    assert.ok(!log.lines.join('\n').includes('push.example'))
    assert.ok(!log.lines.join('\n').includes('push rejected:'))
  })
})

test('notify reports failures and keeps the subscription', async () => {
  await withPush(async () => rejection(503)(), async ({ push, webpush, log }) => {
    push.subscribe('dev_one', subscription('one'))
    const result = await push.notify({ kind: 'approval', reqId: 'r_test' })
    assert.deepEqual(result, { sent: 0, failed: 1, errors: [{ status: 503 }] })
    assert.equal(push.hasSubscriptions(), true)
    assert.ok(log.lines.some(line => line.includes('503')))
    assert.ok(!log.lines.join('\n').includes('push.example'))
    const payload = webpush.calls[0].payload
    assert.ok(payload.includes('Approval needed'))
    assert.ok(!payload.includes('command'))
    assert.ok(!payload.includes('displayReason'))
    assert.ok(!payload.includes('sessionId'))
  })
})
