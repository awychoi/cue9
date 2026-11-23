import test from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createMoteAttention } from '../lib/mote-attention.js'
import { classifyServeStatus, resetSetup } from '../lib/setup.js'

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

async function waitFor(predicate, timeoutMs = 2500) {
  const started = Date.now()
  while (!predicate()) {
    if (Date.now() - started > timeoutMs) throw new Error('timed out waiting for condition')
    await sleep(5)
  }
}

async function startServer({ status = 200, delayMs = 0 } = {}) {
  const requests = []
  let inFlight = 0
  let maxInFlight = 0
  const server = http.createServer((req, res) => {
    inFlight += 1
    maxInFlight = Math.max(maxInFlight, inFlight)
    const chunks = []
    req.on('data', chunk => chunks.push(chunk))
    req.on('end', async () => {
      requests.push({
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      })
      if (delayMs > 0) await sleep(delayMs)
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end('{}')
      inFlight -= 1
    })
  })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })
  const { port } = server.address()
  return {
    origin: `http://127.0.0.1:${port}`,
    requests,
    get maxInFlight() { return maxInFlight },
    async close() {
      server.closeAllConnections?.()
      await new Promise(resolve => server.close(resolve))
    },
  }
}

test('mote: hold previews approval, release sends live once with exact header', async t => {
  const server = await startServer()
  t.after(() => server.close())
  const attention = createMoteAttention({ origin: () => server.origin, log: () => {} })

  attention.hold('r1', 'approval')
  await waitFor(() => server.requests.length === 1)
  const preview = server.requests[0]
  assert.equal(preview.method, 'POST')
  assert.equal(preview.url, '/plugins/cue9/preview')
  assert.equal(preview.headers['x-cue9-action'], '1')
  assert.match(preview.headers['content-type'], /application\/json/)
  assert.deepEqual(JSON.parse(preview.body), { action: 'approval' })

  attention.release('r1')
  await waitFor(() => server.requests.length === 2)
  const live = server.requests[1]
  assert.equal(live.method, 'POST')
  assert.equal(live.url, '/plugins/cue9/live')
  assert.equal(live.headers['x-cue9-action'], '1')
  assert.match(live.headers['content-type'], /application\/json/)
  assert.equal(live.body, '')

  attention.release('r1')
  await sleep(40)
  assert.equal(server.requests.length, 2, 'second release must not send again')
})

test('mote: multiple holds serialize, latest kind wins, live waits for the last release', async t => {
  const server = await startServer({ delayMs: 50 })
  t.after(() => server.close())
  const attention = createMoteAttention({ origin: () => server.origin, log: () => {} })

  attention.hold('a', 'approval')
  await waitFor(() => server.requests.length === 1)
  assert.deepEqual(JSON.parse(server.requests[0].body), { action: 'approval' })

  attention.hold('b', 'question')
  await waitFor(() => server.requests.length === 2)
  assert.equal(server.requests[1].url, '/plugins/cue9/preview')
  assert.deepEqual(JSON.parse(server.requests[1].body), { action: 'question' })
  assert.equal(server.maxInFlight, 1, 'mote calls must be serialized')

  attention.release('a')
  await sleep(80)
  assert.equal(server.requests.length, 2, 'b is still held; no live yet')
  assert.equal(server.requests.at(-1).url, '/plugins/cue9/preview')

  attention.release('b')
  await waitFor(() => server.requests.length === 3)
  assert.equal(server.requests[2].url, '/plugins/cue9/live')
  assert.equal(server.maxInFlight, 1)
})

test('mote: releasing the latest kind falls back to the previous held kind', async t => {
  const server = await startServer()
  t.after(() => server.close())
  const attention = createMoteAttention({ origin: () => server.origin, log: () => {} })

  attention.hold('a', 'approval')
  await waitFor(() => server.requests.length === 1)
  attention.hold('b', 'question')
  await waitFor(() => server.requests.length === 2)
  attention.release('b')
  await waitFor(() => server.requests.length === 3)
  assert.deepEqual(JSON.parse(server.requests[2].body), { action: 'approval' })
  attention.release('a')
  await waitFor(() => server.requests.length === 4)
  assert.equal(server.requests[3].url, '/plugins/cue9/live')
})

test('mote: 400 is ignored, network failures are swallowed and logged once', async () => {
  const server = await startServer({ status: 400 })
  const logs = []
  const attention = createMoteAttention({
    origin: () => server.origin,
    log: message => logs.push(message),
  })
  try {
    assert.doesNotThrow(() => attention.hold('a', 'approval'))
    await waitFor(() => server.requests.length === 1)
    assert.equal(logs.length, 0, '400 means the mote is already urgent; do not log it')
    assert.doesNotThrow(() => attention.release('a'))
    await waitFor(() => server.requests.length === 2)
    assert.equal(logs.length, 0)
  } finally {
    await server.close()
  }

  const failingLogs = []
  const failing = createMoteAttention({
    origin: () => 'http://127.0.0.1:1',
    fetchImpl: async () => { throw new Error('boom') },
    log: message => failingLogs.push(message),
  })
  assert.doesNotThrow(() => failing.hold('b', 'question'))
  await waitFor(() => failingLogs.length === 1)
  assert.doesNotThrow(() => failing.release('b'))
  await sleep(30)
  assert.equal(failingLogs.length, 1, 'failure logging is throttled')
})

test('mote: undefined origin skips cleanly', async () => {
  const attention = createMoteAttention({ origin: () => undefined, log: () => {} })
  assert.doesNotThrow(() => attention.hold('a', 'approval'))
  assert.doesNotThrow(() => attention.release('a'))
  await sleep(20)
})

/* Setup reset: pure classifier and the real cleanup with injected paths/exec. */

const OUR_STATUS = {
  TCP: { 8443: { HTTPS: true } },
  Web: {
    'mbpmax64.tailf17d82.ts.net:8443': {
      Handlers: { '/': { Proxy: 'http://127.0.0.1:8791' } },
    },
  },
}

test('setup: Serve classifier only accepts exactly the cue9 route', () => {
  assert.deepEqual(classifyServeStatus(OUR_STATUS, 8791), { mode: 'ours' })
  assert.deepEqual(classifyServeStatus({}, 8791), { mode: 'empty' })
  assert.deepEqual(classifyServeStatus({ Web: {}, TCP: {} }, 8791), { mode: 'empty' })

  const other = {
    TCP: { 8443: { HTTPS: true }, 443: { HTTPS: true } },
    Web: {
      ...OUR_STATUS.Web,
      'mbpmax64.tailf17d82.ts.net:443': {
        Handlers: { '/': { Proxy: 'http://127.0.0.1:3000' } },
      },
    },
  }
  const plan = classifyServeStatus(other, 8791)
  assert.equal(plan.mode, 'other')
  assert.match(plan.leftover, /8443/)

  const wrongProxy = {
    ...OUR_STATUS,
    Web: {
      'mbpmax64.tailf17d82.ts.net:8443': {
        Handlers: { '/': { Proxy: 'http://127.0.0.1:9999' } },
      },
    },
  }
  assert.equal(classifyServeStatus(wrongProxy, 8791).mode, 'other')
  assert.equal(classifyServeStatus(null, 8791).mode, 'other')
})

function resetFixture({ withCertificate = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'cue9-reset-'))
  const paths = {
    configPath: join(dir, 'phone.json'),
    tlsDir: join(dir, 'tls'),
    certFile: join(dir, 'tls', 'cert.pem'),
    keyFile: join(dir, 'tls', 'key.pem'),
  }
  writeFileSync(paths.configPath, '{"publicOrigin":"https://old.example:8443"}\n')
  if (withCertificate) {
    mkdirSync(paths.tlsDir)
    writeFileSync(paths.certFile, 'certificate')
    writeFileSync(paths.keyFile, 'key')
  }
  return { dir, paths }
}

test('setup: reset revokes, stops, removes local state and resets only our Serve route', async () => {
  const fixture = resetFixture()
  const config = {
    port: 8791,
    publicOrigin: 'https://mbpmax64.tailf17d82.ts.net:8443',
    lan: { host: '192.168.1.108', port: 8443 },
  }
  let stopped = 0
  let pushRemoved = 0
  const calls = []
  const runCommand = async (_command, args) => {
    calls.push(args.join(' '))
    if (args.join(' ') === 'serve status --json') return { stdout: JSON.stringify(OUR_STATUS), stderr: '' }
    if (args.join(' ') === 'serve reset') return { stdout: '', stderr: '' }
    throw new Error(`unexpected command: ${args.join(' ')}`)
  }
  try {
    const result = await resetSetup({
      config,
      phone: { stop: async () => { stopped += 1 } },
      push: { removeAll: () => { pushRemoved += 1 } },
      sessions: { revokeAll: () => 2 },
      log: () => {},
      paths: fixture.paths,
      runCommand,
    })
    assert.deepEqual(result, { ok: true, revoked: 2, serveReset: true })
    assert.equal(config.publicOrigin, undefined)
    assert.equal(config.lan, undefined)
    assert.equal(config.port, 8791)
    assert.equal(stopped, 1)
    assert.equal(pushRemoved, 1)
    assert.deepEqual(calls, ['serve status --json', 'serve reset'])
    assert.equal(existsSync(fixture.paths.configPath), false)
    assert.equal(existsSync(fixture.paths.certFile), false)
    assert.equal(existsSync(fixture.paths.keyFile), false)
    assert.equal(existsSync(fixture.paths.tlsDir), false)
  } finally {
    rmSync(fixture.dir, { recursive: true, force: true })
  }
})

test('setup: reset leaves other Serve config alone and names the 8443 route', async () => {
  const fixture = resetFixture()
  const config = { port: 8791, publicOrigin: 'https://host:8443', lan: { host: '192.168.1.108' } }
  const calls = []
  const runCommand = async (_command, args) => {
    calls.push(args.join(' '))
    if (args.join(' ') === 'serve status --json') {
      return {
        stdout: JSON.stringify({
          TCP: { 8443: { HTTPS: true }, 443: { HTTPS: true } },
          Web: {
            ...OUR_STATUS.Web,
            'host:443': { Handlers: { '/': { Proxy: 'http://127.0.0.1:3000' } } },
          },
        }),
        stderr: '',
      }
    }
    throw new Error('must not reset other Serve config')
  }
  try {
    const result = await resetSetup({
      config,
      phone: { stop: async () => {} },
      push: { removeAll: () => {} },
      sessions: { revokeAll: () => 0 },
      log: () => {},
      paths: fixture.paths,
      runCommand,
    })
    assert.equal(result.ok, true)
    assert.equal(result.serveReset, false)
    assert.match(result.warning, /8443/)
    assert.deepEqual(calls, ['serve status --json'])
    assert.equal(existsSync(fixture.paths.configPath), false)
    assert.equal(config.publicOrigin, undefined)
  } finally {
    rmSync(fixture.dir, { recursive: true, force: true })
  }
})

test('setup: reset survives a status failure, missing files and an absent phone', async () => {
  const fixture = resetFixture({ withCertificate: false })
  const config = { port: 8791, publicOrigin: 'https://host:8443', lan: { host: 'x' } }
  try {
    const result = await resetSetup({
      config,
      phone: undefined,
      push: { removeAll: () => {} },
      sessions: { revokeAll: () => 0 },
      log: () => {},
      paths: fixture.paths,
      runCommand: async () => { throw new Error('tailscale unavailable') },
    })
    assert.equal(result.ok, true)
    assert.equal(result.revoked, 0)
    assert.equal(result.serveReset, false)
    assert.match(result.warning, /Tailscale Serve status/)
    assert.equal(config.publicOrigin, undefined)
    assert.equal(existsSync(fixture.paths.configPath), false)
  } finally {
    rmSync(fixture.dir, { recursive: true, force: true })
  }
})
